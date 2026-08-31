[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet(
        'Menu', 'List', 'Packages', 'Export',
        'Import', 'Verify', 'Delete', 'PackageDelete', 'Download',
        'ComfyUIList', 'ComfyUIDownload', 'ComfyUIDelete'
    )]
    [string]$Action = 'Menu',
    [string]$ModelSelection,
    [string]$PackageSelection,
    [switch]$All,
    [switch]$ConfirmDelete,
    [switch]$ValidateOnly,
    [switch]$NoPause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-ManagerJson {
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
function Write-ManagerBootstrapRule {
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
function Write-ManagerBootstrapLine {
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
function Get-ManagerBootstrapStatusStyle {
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
function Get-ManagerBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-ManagerBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-ManagerBootstrapStatus {
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
    $style = Get-ManagerBootstrapStatusStyle -Level $Level
    $width = Get-ManagerBootstrapStatusWidth
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
function Format-ManagerBootstrapInputLine {
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
function ConvertFrom-ManagerBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-ManagerBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-ManagerBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-ManagerBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-ManagerBootstrapReadValue -Value '') -cne '') {
        throw 'Model yoneticisi bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-ManagerBootstrapExactExit -Value $invalid) {
            throw 'Model yoneticisi bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-ManagerBootstrapExactExit -Value 'CIKIS')) {
        throw 'Model yoneticisi bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:ModelManager.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:ModelManager.BootstrapExactExit'
    return $true
}
function Read-ManagerBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-ManagerBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-ManagerBootstrapInputLine -Value $value))
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
                (Format-ManagerBootstrapInputLine -Value $value))
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
            (Format-ManagerBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-ManagerBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-ManagerBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-ManagerBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Context = Get-WinlamaUIString `
            -Key 'Manager.Operation.FailedContext' -Fallback $Context
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-ManagerBootstrapRule -Character '='
    Write-ManagerBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-ManagerBootstrapStatus -Level ERROR -Message $Context
    Write-ManagerBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-ManagerBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-ManagerBootstrapRule -Character '='
}
function Read-ManagerBootstrapInput {
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
    Write-ManagerBootstrapRule
    Write-ManagerBootstrapStatus -Level INFO -Message $Prompt
    Write-ManagerBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-ManagerBootstrapRule
    $value = Read-ManagerBootstrapRawInput
    Write-ManagerBootstrapRule
    return $value
}
trap {
    Write-ManagerBootstrapError `
        -Context 'Beklenmeyen model yoneticisi hatasi.' `
        -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-ManagerBootstrapInput `
                -Prompt 'Oturumu kapatmak icin CIKIS yazin.'
            if (-not (Test-ManagerBootstrapExactExit -Value $answer)) {
                Write-ManagerBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-ManagerBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'Manager.WindowTitle' `
        -Fallback 'Winlama - Model yoneticisi'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
function Resolve-ManagerConfigPath {
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
$ConfigPath = Resolve-ManagerConfigPath -Path $ConfigPath
$script:ManagerConfig = $null
$script:LogPath = $null
$localizationModule = Join-Path $PSScriptRoot `
    'Modules\Localization\LocalizationManager.psm1'
if (Test-Path -LiteralPath $localizationModule -PathType Leaf) {
    try {
        Import-Module $localizationModule -Force -ErrorAction Stop `
            -Verbose:$false
        $localizationConfig = $null
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            $localizationConfig = (
                Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
                    ConvertFrom-ManagerJson
            ).Localization
        }
        $null = Initialize-Localization -ProjectRoot $PSScriptRoot `
            -Configuration $localizationConfig
        try {
            $host.UI.RawUI.WindowTitle = Get-LocalizedText `
                -Key 'Manager.WindowTitle'
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
    'Modules\00_Common.psm1') -Force -ErrorAction Stop `
    -Verbose:$false
function Write-ManagerRule {
    param([ValidateSet('-', '=')][string]$Character = '-')
    Write-WinlamaUIRule -Character $Character
}
function Write-ManagerLine {
    param(
        [AllowEmptyString()]
        [string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-WinlamaUILine -Text $Text -Color $Color
}
function New-ManagerKeyValueTableColumns {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray
    )
    return @(
        New-WinlamaUITableColumn -Text $Label -Width 22 `
            -Color Cyan
        New-WinlamaUITableColumn -Text $Value -Width 71 `
            -Color $ValueColor
    )
}
function Write-ManagerKeyValueTableRow {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray
    )
    $columns = @(New-ManagerKeyValueTableColumns `
        -Label $Label -Value $Value -ValueColor $ValueColor)
    Write-WinlamaUITableRow -Columns $columns
}
function Assert-ManagerKeyValueTableContracts {
    $columns = @(New-ManagerKeyValueTableColumns `
        -Label (Get-LocalizedText -Key 'Manager.Path.ModelSearchLabel') `
        -Value ('C:\Winlama\Models\' +
            ('cok-uzun-model-klasoru\' * 7) +
            'model.safetensors'))
    $rows = @(Format-WinlamaUITableRow -Columns $columns)
    if ($rows.Count -lt 2 -or
        @($rows | Where-Object { $_.Text.Length -ne 100 }).Count `
            -ne 0 -or
        $rows[0].Text[25] -cne '|' -or
        -not [string]::IsNullOrWhiteSpace($rows[1].Cells[0]) -or
        $rows[0].Cells[0].Length -ne 22 -or
        $rows[0].Cells[1].Length -ne 71) {
        throw 'Model yoneticisi yol tablosu UI sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:ModelManager.PathTable'
    return $true
}
function Write-ManagerBanner {
    Write-ManagerRule -Character '='
    Write-ManagerLine -Text (Get-LocalizedText `
        -Key 'Manager.Banner.Title') `
        -Color Cyan
    Write-ManagerLine -Text (Get-LocalizedText `
        -Key 'Manager.Banner.Subtitle') `
        -Color Cyan
    Write-ManagerRule -Character '='
}
function Write-ManagerSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [object[]]$TitleArguments = @(),
        [switch]$NoLeadingRule
    )
    if (-not $NoLeadingRule) {
        Write-ManagerRule
    }
    Write-ManagerLine -Text (' {0}' -f (
        Get-LocalizedText -Key $Title -Arguments $TitleArguments
    )) -Color Cyan
    Write-ManagerRule
}
function Write-ManagerStatus {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'SKIP')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [object[]]$MessageArguments = @()
    )
    $Message = Get-LocalizedText -Key $Message `
        -Arguments $MessageArguments
    $uiLevel = switch ($Level) {
        'OK' { 'SUCCESS' }
        'WARN' { 'WARN' }
        'ERROR' { 'ERROR' }
        'SKIP' { 'SKIP' }
        default { 'INFO' }
    }
    Write-WinlamaUIStatus -Level $uiLevel -Message $Message
}
function Read-ManagerInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = ('Se{0}iminiz' -f [char]0x00E7),
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    return Read-WinlamaUIInput -Prompt $Prompt -Label $Label `
        -InputReader $InputReader -NoLeadingRule:$NoLeadingRule
}
function Confirm-ManagerAction {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    return Confirm-WinlamaUIAction -Prompt $Prompt `
        -InputReader $InputReader -NoLeadingRule:$NoLeadingRule
}
function Write-ManagerError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    Write-WinlamaUIError -Context $Context -ErrorRecord $ErrorRecord
}
function Expand-ManagerPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $PSScriptRoot $expanded
    }
    return [IO.Path]::GetFullPath($expanded)
}
function Write-ManagerLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Event,
        [Parameter(Mandatory)]
        [string]$Message,
        [object[]]$MessageArguments = @(),
        [object]$Data
    )
    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        return
    }
    $Message = Get-LocalizedText -Key $Message `
        -Arguments $MessageArguments
    $localizedLevel = switch ($Level) {
        'ERROR' { Get-LocalizedText -Key 'Common.Level.Error' }
        'WARN' { Get-LocalizedText -Key 'Common.Level.Warning' }
        default { Get-LocalizedText -Key 'Common.Level.Info' }
    }
    $entry = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = $Level
        displayLevel = $localizedLevel
        module = Get-LocalizedText -Key 'Module.ModelManager'
        moduleCode = 'MODEL_MANAGER'
        event = Get-LocalizedText -Key "Manager.Event.$Event"
        eventCode = $Event
        message = $Message
        processId = $PID
        data = $Data
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 12
    try {
        Add-WinlamaUtf8Line -Path $script:LogPath -Value $line
    }
    catch {
        Write-Verbose ('MODEL_MANAGER_LOG_WRITE_FAILED: {0}' -f `
            $_.Exception.Message)
    }
}
function Initialize-Manager {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Manager.Error.ConfigMissing' `
            -Arguments @($ConfigPath))
    }
    $script:ManagerConfig = Get-Content -LiteralPath $ConfigPath `
        -Raw -Encoding UTF8 | ConvertFrom-ManagerJson
    if ($null -ne (Get-Command Initialize-Localization `
        -ErrorAction SilentlyContinue)) {
        $null = Initialize-Localization -ProjectRoot $PSScriptRoot `
            -Configuration $script:ManagerConfig.Localization
    }
    $required = @(
        'ProjectName', 'EngineVersion', 'MinimumPowerShellVersion',
        'Localization', 'Paths', 'ModelTransfer', 'Ollama',
        'OpenWebUI', 'ComfyUI', 'Runtime', 'Models',
        'Network', 'Security'
    )
    foreach ($name in $required) {
        if ($null -eq $script:ManagerConfig.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.ConfigFieldMissing' `
                -Arguments @($name))
        }
    }
    foreach ($name in @('Host', 'ApiHost', 'Port', 'AllowedOrigins')) {
        if ($null -eq $script:ManagerConfig.Ollama.
            PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.ConfigFieldMissing' `
                -Arguments @("Ollama.$name"))
        }
    }
    if ($null -eq $script:ManagerConfig.OpenWebUI.
        PSObject.Properties['Port']) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ConfigFieldMissing' `
            -Arguments @('OpenWebUI.Port'))
    }
    foreach ($name in @(
        'Enabled', 'ModelsPath', 'Catalog'
    )) {
        if ($null -eq $script:ManagerConfig.ComfyUI.
            PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.ConfigFieldMissing' `
                -Arguments @("ComfyUI.$name"))
        }
    }
    if (@($script:ManagerConfig.ComfyUI.Catalog).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ModelCatalogEmpty')
    }
    if ($null -eq $script:ManagerConfig.Security.
        PSObject.Properties['LanAccess']) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ConfigFieldMissing' `
            -Arguments @('Security.LanAccess'))
    }
    if ($script:ManagerConfig.ModelTransfer.PackageFormatVersion -ne 1) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageFormatUnsupported')
    }
    if (@($script:ManagerConfig.Models.Catalog).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ModelCatalogEmpty')
    }
    if ($PSVersionTable.PSVersion -lt
        [version]$script:ManagerConfig.ModelTransfer.
            MinimumPowerShellVersion) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PowerShellUnsupported')
    }
    if (@($script:ManagerConfig.ModelTransfer.
        NativeModelSearchDirectories).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.NativeSearchDirectoryMissing')
    }
    $bufferSize = $script:ManagerConfig.ModelTransfer.BufferSizeMB
    if ($bufferSize -lt 1 -or $bufferSize -gt 64) {
        throw (Get-LocalizedText -Key 'Manager.Error.BufferInvalid')
    }
    if ($ValidateOnly) {
        return
    }
    $deploymentRoot = Resolve-ConfigurationPath `
        -Path ([string]$script:ManagerConfig.Paths.Root) `
        -BasePath $PSScriptRoot
    $configuredLog = Resolve-ConfigurationPath `
        -Path ([string]$script:ManagerConfig.ModelTransfer.LogPath) `
        -BasePath $deploymentRoot
    $deploymentPrefix = $deploymentRoot.TrimEnd('\') + '\'
    if (-not $configuredLog.StartsWith(
        $deploymentPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ConfigFieldMissing' `
            -Arguments @('ModelTransfer.LogPath'))
    }
    $script:LogPath = New-WinlamaTimestampedFile `
        -Directory (Split-Path -Parent $configuredLog) `
        -Extension '.log'
    Write-ManagerLog -Level INFO -Event START `
        -Message 'Manager.Log.Started' `
        -Data @{ Action = $Action; ConfigPath = $ConfigPath }
}
function Get-JsonValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$DefaultValue
    )
    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}
function Resolve-SafeChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.AbsoluteChildPath' `
            -Arguments @($RelativePath))
    }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path $fullRoot $RelativePath)
    )
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-LocalizedText -Key 'Manager.Error.PathEscapesRoot' `
            -Arguments @($RelativePath))
    }
    return $fullPath
}
function Get-RelativeManagerPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-LocalizedText -Key 'Manager.Error.PathOutsideRoot' `
            -Arguments @($Path))
    }
    return $fullPath.Substring($prefix.Length)
}
function Convert-DigestToFileName {
    param([Parameter(Mandatory)][string]$Digest)
    if ($Digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw (Get-LocalizedText -Key 'Manager.Error.BlobDigestInvalid' `
            -Arguments @($Digest))
    }
    return 'sha256-' + $Matches[1].ToLowerInvariant()
}
function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
}
function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) {
        return '{0:N2} TB' -f ($Bytes / 1TB)
    }
    if ($Bytes -ge 1GB) {
        return '{0:N2} GB' -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return '{0:N2} MB' -f ($Bytes / 1MB)
    }
    return '{0:N0} B' -f $Bytes
}
function Get-ManifestDescriptors {
    param([Parameter(Mandatory)][object]$Manifest)
    $schemaVersion = Get-JsonValue -InputObject $Manifest `
        -Name schemaVersion -DefaultValue 0
    if ([int]$schemaVersion -ne 2) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ManifestSchemaUnsupported' `
            -Arguments @($schemaVersion))
    }
    $configDescriptor = Get-JsonValue -InputObject $Manifest `
        -Name config -DefaultValue $null
    if ($null -eq $configDescriptor) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ManifestConfigMissing')
    }
    $layers = @(Get-JsonValue -InputObject $Manifest `
        -Name layers -DefaultValue @())
    $items = @($configDescriptor) + $layers
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $descriptors = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $digest = [string](Get-JsonValue -InputObject $item `
            -Name digest -DefaultValue '')
        $fileName = Convert-DigestToFileName -Digest $digest
        if (-not $seen.Add($digest)) {
            continue
        }
        $size = [long](Get-JsonValue -InputObject $item `
            -Name size -DefaultValue 0)
        if ($size -lt 0) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.BlobSizeInvalid' `
                -Arguments @($digest))
        }
        $mediaType = [string](Get-JsonValue -InputObject $item `
            -Name mediaType -DefaultValue '')
        $descriptors.Add([pscustomobject]@{
            Digest = $digest.ToLowerInvariant()
            FileName = $fileName
            Size = $size
            MediaType = $mediaType
        })
    }
    return $descriptors.ToArray()
}
function Get-ModelIdentity {
    param([Parameter(Mandatory)][string]$ManifestRelativePath)
    $normalized = $ManifestRelativePath.Replace('\', '/')
    $segments = @($normalized.Split('/') | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($segments.Count -lt 4) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ManifestIdentityMissing' `
            -Arguments @($normalized))
    }
    foreach ($segment in $segments) {
        if ($segment -in @('.', '..')) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.ManifestPathInvalid' `
                -Arguments @($normalized))
        }
    }
    $registry = $segments[0]
    $tag = $segments[$segments.Count - 1]
    $model = $segments[$segments.Count - 2]
    $namespaceEnd = $segments.Count - 3
    $namespace = @($segments[1..$namespaceEnd]) -join '/'
    $exact = "$registry/$namespace/$model`:$tag"
    $reference = $exact
    if ($registry -ieq 'registry.ollama.ai') {
        $reference = "$namespace/$model`:$tag"
        if ($namespace -ieq 'library') {
            $reference = "$model`:$tag"
        }
    }
    return [pscustomobject]@{
        Registry = $registry
        Namespace = $namespace
        Model = $model
        Tag = $tag
        ExactReference = $exact
        OllamaReference = $reference
        ManifestRelativePath = $normalized
    }
}
function Read-NativeModel {
    param(
        [Parameter(Mandatory)][string]$ManifestRoot,
        [Parameter(Mandatory)][string]$BlobRoot,
        [Parameter(Mandatory)][IO.FileInfo]$ManifestFile
    )
    $relative = Get-RelativeManagerPath -Root $ManifestRoot `
        -Path $ManifestFile.FullName
    $identity = Get-ModelIdentity -ManifestRelativePath $relative
    $manifest = Get-Content -LiteralPath $ManifestFile.FullName `
        -Raw -Encoding UTF8 | ConvertFrom-ManagerJson
    $descriptors = @(Get-ManifestDescriptors -Manifest $manifest)
    $missing = [Collections.Generic.List[string]]::new()
    $totalBytes = [long]0
    foreach ($descriptor in $descriptors) {
        $blobPath = Join-Path $BlobRoot $descriptor.FileName
        if (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
            $missing.Add($descriptor.Digest)
            continue
        }
        $length = (Get-Item -LiteralPath $blobPath).Length
        if ($descriptor.Size -gt 0 -and $length -ne $descriptor.Size) {
            $missing.Add($descriptor.Digest)
            continue
        }
        $totalBytes += $length
    }
    return [pscustomobject]@{
        Identity = $identity
        ModelsRoot = (Split-Path -Parent $ManifestRoot)
        BlobRoot = $BlobRoot
        ManifestPath = $ManifestFile.FullName
        Manifest = $manifest
        Descriptors = $descriptors
        TotalBytes = $totalBytes
        Missing = $missing.ToArray()
        IsReady = $missing.Count -eq 0
    }
}
function Get-NativeModelSearchDirectories {
    $directories = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $configured = @($script:ManagerConfig.Paths.Models) +
        @($script:ManagerConfig.ModelTransfer.
            NativeModelSearchDirectories)
    foreach ($value in $configured) {
        $path = Expand-ManagerPath -Path ([string]$value)
        if ($seen.Add($path)) {
            $directories.Add($path)
        }
    }
    return $directories.ToArray()
}
function Get-NativeModels {
    $models = [Collections.Generic.List[object]]::new()
    $references = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($modelsRoot in @(Get-NativeModelSearchDirectories)) {
        $manifestRoot = Join-Path $modelsRoot 'manifests'
        $blobRoot = Join-Path $modelsRoot 'blobs'
        if (-not (Test-Path -LiteralPath $manifestRoot `
            -PathType Container)) {
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $manifestRoot `
            -Recurse -File -ErrorAction Stop)
        foreach ($file in $files) {
            try {
                $model = Read-NativeModel -ManifestRoot $manifestRoot `
                    -BlobRoot $blobRoot -ManifestFile $file
                if ($references.Add($model.Identity.ExactReference)) {
                    $models.Add($model)
                }
                else {
                    Write-ManagerLog -Level INFO `
                        -Event NATIVE_DUPLICATE `
                        -Message 'Manager.Log.NativeDuplicate' `
                        -Data @{ Model = $model.Identity.ExactReference;
                            Path = $file.FullName }
                }
            }
            catch {
                Write-ManagerLog -Level WARN -Event NATIVE_MANIFEST `
                    -Message 'Manager.Log.NativeManifestInvalid' `
                    -Data @{
                        Path = $file.FullName
                        Error = $_.Exception.Message
                    }
            }
        }
    }
    return @($models.ToArray() | Sort-Object {
        $_.Identity.OllamaReference
    })
}
function Show-NativeModels {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Models
    )
    Write-ManagerSection -Title 'Manager.Section.NativeModels'
    if ($Models.Count -eq 0) {
        Write-ManagerStatus -Level WARN `
            -Message 'Manager.Native.None'
        foreach ($path in @(Get-NativeModelSearchDirectories)) {
            Write-ManagerKeyValueTableRow `
                -Label (Get-LocalizedText `
                    -Key 'Manager.Path.SearchedLabel') `
                -Value $path
        }
        return
    }
    for ($index = 0; $index -lt $Models.Count; $index++) {
        $model = $Models[$index]
        $status = Get-LocalizedText -Key 'Common.Status.Ready'
        $color = 'Green'
        if (-not $model.IsReady) {
            $status = Get-LocalizedText -Key 'Common.Status.Missing' `
                -Arguments @($model.Missing.Count)
            $color = 'Red'
        }
        $number = $index + 1
        Write-ManagerLine `
            -Text (Get-LocalizedText -Key 'Manager.Native.Row' `
                -Arguments @(
                    $number,
                    $model.Identity.OllamaReference,
                    (Format-ByteSize -Bytes $model.TotalBytes),
                    $status
                )) -Color $color
        Write-ManagerKeyValueTableRow `
            -Label (Get-LocalizedText `
                -Key 'Manager.Native.IdentityLabel') `
            -Value $model.Identity.ExactReference
        Write-ManagerKeyValueTableRow `
            -Label (Get-LocalizedText `
                -Key 'Manager.Native.SourceLabel') `
            -Value $model.ModelsRoot
    }
    Write-ManagerRule
}
function Copy-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$Activity
    )
    $destinationDirectory = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    $temporary = Join-Path $destinationDirectory `
        ('.{0}.{1}.tmp' -f `
            ([IO.Path]::GetFileName($Destination)),
            [guid]::NewGuid().ToString('N'))
    $bufferBytes = [int](
        $script:ManagerConfig.ModelTransfer.BufferSizeMB * 1MB
    )
    $buffer = [byte[]]::new($bufferBytes)
    $sourceStream = $null
    $destinationStream = $null
    $hasher = $null
    try {
        $sourceStream = [IO.File]::Open(
            $Source,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $destinationStream = [IO.File]::Open(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
            [Security.Cryptography.HashAlgorithmName]::SHA256
        )
        $total = $sourceStream.Length
        $completed = [long]0
        while (($read = $sourceStream.Read(
            $buffer,
            0,
            $buffer.Length
        )) -gt 0) {
            $destinationStream.Write($buffer, 0, $read)
            $hasher.AppendData($buffer, 0, $read)
            $completed += $read
            $percent = 100
            if ($total -gt 0) {
                $percent = [Math]::Min(
                    100,
                    [int](($completed * 100) / $total)
                )
            }
            $status = '{0} / {1}' -f `
                (Format-ByteSize -Bytes $completed),
                (Format-ByteSize -Bytes $total)
            Write-Progress -Activity $Activity -Status $status `
                -PercentComplete $percent
        }
        $destinationStream.Flush($true)
        $hashBytes = $hasher.GetHashAndReset()
        $hash = [BitConverter]::ToString($hashBytes).
            Replace('-', '').ToLowerInvariant()
        if ($hash -ne $ExpectedHash.ToLowerInvariant()) {
            throw (Get-LocalizedText -Key 'Manager.Error.HashMismatch' `
                -Arguments @($Source))
        }
        $destinationStream.Dispose()
        $destinationStream = $null
        $sourceStream.Dispose()
        $sourceStream = $null
        [IO.File]::Move($temporary, $Destination)
        Write-Progress -Activity $Activity -Completed
        return $hash
    }
    finally {
        if ($null -ne $hasher) {
            $hasher.Dispose()
        }
        if ($null -ne $destinationStream) {
            $destinationStream.Dispose()
        }
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}
function Write-Utf8Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    $json = ConvertTo-StableJson -Value $Value -Depth 20
    [IO.File]::WriteAllText(
        $Path,
        $json,
        [Text.UTF8Encoding]::new($false)
    )
}
function Get-ExportPackagePath {
    param(
        [Parameter(Mandatory)][string]$ExportRoot,
        [Parameter(Mandatory)][object]$Identity
    )
    $relativePath = Join-Path $Identity.Model $Identity.Tag
    if ($Identity.Registry -ine 'registry.ollama.ai' -or
        $Identity.Namespace -ine 'library') {
        $relativePath = Join-Path $Identity.Registry (
            Join-Path $Identity.Namespace $relativePath
        )
    }
    return Resolve-SafeChildPath -Root $ExportRoot `
        -RelativePath $relativePath
}
function Assert-ExportDiskSpace {
    param(
        [Parameter(Mandatory)][object]$Model,
        [Parameter(Mandatory)][string]$ExportRoot
    )
    $driveRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath($ExportRoot)
    )
    $freeBytes = [IO.DriveInfo]::new($driveRoot).
        AvailableFreeSpace
    $requiredBytes = [long]$Model.TotalBytes + 128MB
    if ($freeBytes -lt $requiredBytes) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ExportDiskInsufficient' `
            -Arguments @(
                $Model.Identity.OllamaReference,
                [math]::Round($requiredBytes / 1GB, 2),
                [math]::Round($freeBytes / 1GB, 2),
                $driveRoot
            ))
    }
}
function Move-ManagerDirectoryAtomically {
    param(
        [Parameter(Mandatory)][string]$Temporary,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination `
        -PathType Container)) {
        Move-Item -LiteralPath $Temporary -Destination $Destination
        return
    }
    $backup = '{0}.winlama-{1}.backup' -f `
        $Destination, [guid]::NewGuid().ToString('N')
    Move-Item -LiteralPath $Destination -Destination $backup
    try {
        Move-Item -LiteralPath $Temporary -Destination $Destination
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
    catch {
        if (-not (Test-Path -LiteralPath $Destination) -and
            (Test-Path -LiteralPath $backup -PathType Container)) {
            Move-Item -LiteralPath $backup `
                -Destination $Destination
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $backup -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
function Export-NativeModel {
    param([Parameter(Mandatory)][object]$Model)
    if (-not $Model.IsReady) {
        throw (Get-LocalizedText -Key 'Manager.Error.ModelFilesMissing' `
            -Arguments @($Model.Identity.OllamaReference))
    }
    $blobRoot = $Model.BlobRoot
    $exportRoot = Expand-ManagerPath -Path `
        $script:ManagerConfig.ModelTransfer.ExportDirectory
    Assert-ExportDiskSpace -Model $Model `
        -ExportRoot $exportRoot
    [IO.Directory]::CreateDirectory($exportRoot) | Out-Null
    $destination = Get-ExportPackagePath -ExportRoot $exportRoot `
        -Identity $Model.Identity
    $parent = Split-Path -Parent $destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent `
        ('.{0}.{1}.tmp' -f `
            ([IO.Path]::GetFileName($destination)),
            [guid]::NewGuid().ToString('N'))
    Write-ManagerLog -Level INFO -Event EXPORT_START `
        -Message 'Manager.Log.ExportStarted' `
        -Data @{ Model = $Model.Identity.ExactReference }
    try {
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        $packageBlobRoot = Join-Path $temporary 'blobs'
        [IO.Directory]::CreateDirectory($packageBlobRoot) | Out-Null
        $manifestHash = Get-FileSha256 -Path $Model.ManifestPath
        $manifestTarget = Resolve-SafeChildPath -Root $temporary `
            -RelativePath (Join-Path 'manifests' `
                $Model.Identity.ManifestRelativePath)
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $manifestTarget)
        ) | Out-Null
        $null = Copy-FileWithProgress -Source $Model.ManifestPath `
            -Destination $manifestTarget -ExpectedHash $manifestHash `
                    -Activity (Get-LocalizedText `
                        -Key 'Manager.Progress.Manifest' `
                        -Arguments @($Model.Identity.OllamaReference))
        $blobMetadata = [Collections.Generic.List[object]]::new()
        $totalBytes = [long]0
        foreach ($descriptor in $Model.Descriptors) {
            $sourceBlob = Join-Path $blobRoot $descriptor.FileName
            if (-not (Test-Path -LiteralPath $sourceBlob `
                -PathType Leaf)) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.BlobMissing' `
                    -Arguments @($descriptor.Digest))
            }
            $sourceLength = (Get-Item -LiteralPath $sourceBlob).Length
            if ($descriptor.Size -gt 0 -and
                $sourceLength -ne $descriptor.Size) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.BlobSizeMismatch' `
                    -Arguments @($descriptor.Digest))
            }
            $expectedHash = $descriptor.Digest.Substring(7)
            $targetBlob = Join-Path $packageBlobRoot `
                $descriptor.FileName
            $null = Copy-FileWithProgress -Source $sourceBlob `
                -Destination $targetBlob -ExpectedHash $expectedHash `
                -Activity ("$($Model.Identity.OllamaReference) | " +
                    $descriptor.FileName.Substring(0, 20))
            $blobMetadata.Add([ordered]@{
                Digest = $descriptor.Digest
                File = "blobs/$($descriptor.FileName)"
                Size = $sourceLength
                MediaType = $descriptor.MediaType
            })
            $totalBytes += $sourceLength
        }
        $currentManifestHash = Get-FileSha256 `
            -Path $Model.ManifestPath
        if ($currentManifestHash -ne $manifestHash) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.SourceManifestChanged')
        }
        $metadata = [ordered]@{
            Format = 'ollama-portable-model'
            FormatVersion = [int]$script:ManagerConfig.
                ModelTransfer.PackageFormatVersion
            OllamaReference = $Model.Identity.OllamaReference
            ExactReference = $Model.Identity.ExactReference
            ManifestRelativePath = $Model.Identity.ManifestRelativePath
            ManifestSha256 = $manifestHash
            ManifestSchemaVersion = 2
            ExportedAt = [DateTimeOffset]::UtcNow.ToString('O')
            EngineVersion = $script:ManagerConfig.EngineVersion
            TotalSizeBytes = $totalBytes
            Blobs = $blobMetadata.ToArray()
        }
        Write-Utf8Json -Path (Join-Path $temporary 'package.json') `
            -Value $metadata
        Move-ManagerDirectoryAtomically -Temporary $temporary `
            -Destination $destination
        Write-ManagerLog -Level INFO -Event EXPORT_SUCCESS `
            -Message 'Manager.Log.ExportCompleted' `
            -Data @{
                Model = $Model.Identity.ExactReference
                Package = $destination
                Size = $totalBytes
            }
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Export.Completed' `
            -MessageArguments @(
                $Model.Identity.OllamaReference,
                $destination
            )
        return $destination
    }
    catch {
        Write-ManagerLog -Level ERROR -Event EXPORT_FAILED `
            -Message 'Manager.Log.ExportFailed' `
            -Data @{
                Model = $Model.Identity.ExactReference
                Error = $_.Exception.Message
            }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Container) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}
function Get-PackageDirectories {
    $roots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PackageSelection)) {
        foreach ($value in $PackageSelection.Split(';')) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $roots.Add((Expand-ManagerPath -Path $value.Trim()))
            }
        }
    }
    else {
        foreach ($value in @($script:ManagerConfig.ModelTransfer.
            ImportSearchDirectories)) {
            $roots.Add((Expand-ManagerPath -Path ([string]$value)))
        }
    }
    $packages = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Leaf) {
            if ([IO.Path]::GetFileName($root) -ieq 'package.json') {
                $null = $packages.Add((Split-Path -Parent $root))
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-ManagerLog -Level WARN -Event PACKAGE_SEARCH `
                -Message 'Manager.Log.PackageSearchMissing' `
                -Data @{ Path = $root }
            continue
        }
        $direct = Join-Path $root 'package.json'
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            $null = $packages.Add($root)
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse `
            -File -Filter 'package.json' -ErrorAction SilentlyContinue) {
            $null = $packages.Add($file.Directory.FullName)
        }
    }
    return @($packages | Sort-Object)
}
function Read-PortablePackage {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [switch]$VerifyHashes
    )
    $metadataPath = Join-Path $PackagePath 'package.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageMetadataMissing' `
            -Arguments @($PackagePath))
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw `
        -Encoding UTF8 | ConvertFrom-ManagerJson
    if ($metadata.Format -ne 'ollama-portable-model' -or
        [int]$metadata.FormatVersion -ne
            [int]$script:ManagerConfig.ModelTransfer.PackageFormatVersion) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageUnsupported' `
            -Arguments @($PackagePath))
    }
    $identity = Get-ModelIdentity `
        -ManifestRelativePath $metadata.ManifestRelativePath
    $manifestPath = Resolve-SafeChildPath -Root $PackagePath `
        -RelativePath (Join-Path 'manifests' `
            $identity.ManifestRelativePath)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageManifestMissing' `
            -Arguments @($PackagePath))
    }
    if ($identity.ExactReference -cne $metadata.ExactReference -or
        $identity.OllamaReference -cne $metadata.OllamaReference) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageIdentityMismatch' `
            -Arguments @($PackagePath))
    }
    $manifestHash = Get-FileSha256 -Path $manifestPath
    if ($manifestHash -ne $metadata.ManifestSha256) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ManifestHashMismatch' `
            -Arguments @($PackagePath))
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw `
        -Encoding UTF8 | ConvertFrom-ManagerJson
    $descriptors = @(Get-ManifestDescriptors -Manifest $manifest)
    $metadataDigests = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($blob in @($metadata.Blobs)) {
        $null = $metadataDigests.Add([string]$blob.Digest)
    }
    foreach ($descriptor in $descriptors) {
        if (-not $metadataDigests.Contains($descriptor.Digest)) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.PackageBlobRecordMissing' `
                -Arguments @($descriptor.Digest))
        }
        $relativeBlob = "blobs/$($descriptor.FileName)"
        $blobPath = Resolve-SafeChildPath -Root $PackagePath `
            -RelativePath $relativeBlob
        if (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.PackageBlobMissing' `
                -Arguments @($descriptor.Digest))
        }
        $length = (Get-Item -LiteralPath $blobPath).Length
        if ($descriptor.Size -gt 0 -and $length -ne $descriptor.Size) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.PackageBlobSizeMismatch' `
                -Arguments @($descriptor.Digest))
        }
        if ($VerifyHashes) {
            $hash = Get-FileSha256 -Path $blobPath
            if ($hash -ne $descriptor.Digest.Substring(7)) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.PackageBlobHashMismatch' `
                    -Arguments @($descriptor.Digest))
            }
        }
    }
    return [pscustomobject]@{
        PackagePath = [IO.Path]::GetFullPath($PackagePath)
        Metadata = $metadata
        Identity = $identity
        ManifestPath = $manifestPath
        Manifest = $manifest
        ManifestHash = $manifestHash
        Descriptors = $descriptors
    }
}
function Get-PackageSummaries {
    $summaries = [Collections.Generic.List[object]]::new()
    foreach ($packagePath in @(Get-PackageDirectories)) {
        try {
            $package = Read-PortablePackage -PackagePath $packagePath
            $summaries.Add([pscustomobject]@{
                PackagePath = $packagePath
                Package = $package
                IsValid = $true
                Error = ''
            })
        }
        catch {
            Write-Verbose ('Model paketi okunamadi: {0} | {1}' -f `
                $packagePath, $_.Exception.Message)
            $summaries.Add([pscustomobject]@{
                PackagePath = $packagePath
                Package = $null
                IsValid = $false
                Error = $_.Exception.Message
            })
        }
    }
    return $summaries.ToArray()
}
function Show-Packages {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Packages
    )
    Write-ManagerSection -Title 'Manager.Section.Packages'
    if ($Packages.Count -eq 0) {
        Write-ManagerStatus -Level WARN -Message 'Manager.Package.None'
        return
    }
    for ($index = 0; $index -lt $Packages.Count; $index++) {
        $item = $Packages[$index]
        $number = $index + 1
        if ($item.IsValid) {
            $reference = $item.Package.Identity.OllamaReference
            $size = [long]$item.Package.Metadata.TotalSizeBytes
            Write-ManagerLine -Text (Get-LocalizedText `
                -Key 'Manager.Package.ValidRow' `
                -Arguments @(
                    $number,
                    $reference,
                    (Format-ByteSize -Bytes $size)
                )) -Color Green
        }
        else {
            Write-ManagerLine -Text (Get-LocalizedText `
                -Key 'Manager.Package.InvalidRow' `
                -Arguments @(
                    $number,
                    [IO.Path]::GetFileName($item.PackagePath)
                )) -Color Red
            Write-ManagerKeyValueTableRow `
                -Label (Get-LocalizedText `
                    -Key 'Manager.Package.ErrorLabel') `
                -Value $item.Error -ValueColor Red
        }
        Write-ManagerKeyValueTableRow `
            -Label (Get-LocalizedText `
                -Key 'Manager.Package.DirectoryLabel') `
            -Value $item.PackagePath
    }
    Write-ManagerRule
}
function Resolve-ModelSelection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Models,
        [switch]$RequireExplicit,
        [switch]$IncludeIncomplete
    )
    $eligible = @(if ($IncludeIncomplete) {
        $Models
    }
    else {
        $Models | Where-Object IsReady
    })
    if ($eligible.Count -eq 0) {
        return @()
    }
    if ($All) {
        return $eligible
    }
    $interactive = [string]::IsNullOrWhiteSpace($ModelSelection)
    while ($true) {
        $selection = $ModelSelection
        if ($interactive) {
            $selection = Read-ManagerInput -Prompt (
                Get-LocalizedText -Key $(if ($RequireExplicit) {
                        'Manager.Prompt.DeleteModels'
                    }
                    else {
                        'Manager.Prompt.Models'
                    })
            )
        }
        if ($selection -in @('0', 'G', 'g')) {
            return @()
        }
        if ([string]::IsNullOrWhiteSpace($selection)) {
            if (-not $interactive) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.ModelSelectionRequired')
            }
            Write-ManagerStatus -Level WARN `
                -Message 'Manager.Delete.SelectionRequired'
            continue
        }
        if ($selection -ieq 'A') {
            return $eligible
        }
        try {
            if ($selection.Trim().StartsWith('-')) {
                $indices = @(Resolve-WinlamaIndexSelection `
                    -Value $selection -Count $Models.Count)
                return @($indices | ForEach-Object {
                    $Models[$_ - 1]
                } | Where-Object {
                    $IncludeIncomplete -or $_.IsReady
                })
            }
            $selected = [Collections.Generic.List[object]]::new()
            $paths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($token in $selection.Split(',')) {
                $value = $token.Trim()
                $model = $null
                $number = 0
                if ([int]::TryParse($value, [ref]$number)) {
                    if ($number -lt 1 -or $number -gt $Models.Count) {
                        throw (Get-LocalizedText `
                            -Key 'Manager.Error.ModelIndexInvalid' `
                            -Arguments @($value))
                    }
                    $model = $Models[$number - 1]
                }
                else {
                    $model = $Models | Where-Object {
                        $_.Identity.OllamaReference -ieq $value -or
                        $_.Identity.ExactReference -ieq $value
                    } | Select-Object -First 1
                }
                if ($null -eq $model) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.ModelNotFound' `
                        -Arguments @($value))
                }
                if (-not $IncludeIncomplete -and -not $model.IsReady) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.ModelFilesMissing' `
                        -Arguments @($value))
                }
                if ($paths.Add($model.ManifestPath)) {
                    $selected.Add($model)
                }
            }
            return $selected.ToArray()
        }
        catch {
            if (-not $interactive) {
                throw
            }
            Write-ManagerStatus -Level WARN `
                -Message $_.Exception.Message
        }
    }
}
function Resolve-PackageSelection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Packages,
        [switch]$RequireExplicit,
        [switch]$IncludeInvalid
    )
    $eligible = @(if ($IncludeInvalid) {
        $Packages
    }
    else {
        $Packages | Where-Object IsValid
    })
    if ($eligible.Count -eq 0) {
        return @()
    }
    if ($All) {
        return $eligible
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageSelection)) {
        $selected = [Collections.Generic.List[object]]::new()
        $paths = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($token in $PackageSelection.Split(';')) {
            $requestedPath = [IO.Path]::GetFullPath($token.Trim()).
                TrimEnd('\')
            $package = $eligible | Where-Object {
                [IO.Path]::GetFullPath($_.PackagePath).TrimEnd('\') `
                    -ieq $requestedPath
            } | Select-Object -First 1
            if ($null -eq $package) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.PackagePathNotFound' `
                    -Arguments @($requestedPath))
            }
            if ($paths.Add($requestedPath)) {
                $selected.Add($package)
            }
        }
        return $selected.ToArray()
    }
    while ($true) {
        $selection = Read-ManagerInput -Prompt (
            Get-LocalizedText -Key $(if ($RequireExplicit) {
                    'Manager.Prompt.DeletePackages'
                }
                else {
                    'Manager.Prompt.Packages'
                })
        )
        if ($selection -in @('0', 'G', 'g')) {
            return @()
        }
        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-ManagerStatus -Level WARN `
                -Message 'Manager.PackageDelete.SelectionRequired'
            continue
        }
        if ($selection -ieq 'A') {
            return $eligible
        }
        try {
            if ($selection.Trim().StartsWith('-')) {
                $indices = @(Resolve-WinlamaIndexSelection `
                    -Value $selection -Count $Packages.Count)
                return @($indices | ForEach-Object {
                    $Packages[$_ - 1]
                } | Where-Object {
                    $IncludeInvalid -or $_.IsValid
                })
            }
            $selected = [Collections.Generic.List[object]]::new()
            $paths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($token in $selection.Split(',')) {
                $number = 0
                if (-not [int]::TryParse(
                    $token.Trim(),
                    [ref]$number
                ) -or $number -lt 1 -or
                    $number -gt $Packages.Count) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.PackageIndexInvalid' `
                        -Arguments @($token))
                }
                $item = $Packages[$number - 1]
                if (-not $IncludeInvalid -and -not $item.IsValid) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.PackageSelectionInvalid' `
                        -Arguments @($number))
                }
                if ($paths.Add($item.PackagePath)) {
                    $selected.Add($item)
                }
            }
            return $selected.ToArray()
        }
        catch {
            Write-ManagerStatus -Level WARN `
                -Message $_.Exception.Message
        }
    }
}
function Suspend-OllamaApplication {
    $root = Expand-ManagerPath -Path `
        $script:ManagerConfig.Ollama.InstallPath
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $processes = @(Get-CimInstance -ClassName Win32_Process `
        -ErrorAction SilentlyContinue | Where-Object {
            $path = [string]$_.ExecutablePath
            -not [string]::IsNullOrWhiteSpace($path) -and
                [IO.Path]::GetFullPath($path).StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
        })
    if ($processes.Count -gt 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Ollama.Stopping'
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return @([pscustomobject]@{
        WasRunning = $processes.Count -gt 0
    })
}
function Resume-OllamaApplication {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$States
    )
    $state = $States | Select-Object -First 1
    if ($null -ne $state -and $state.WasRunning -and
        -not (Test-ManagerOllamaApplicationRunning)) {
        Start-ManagerOllamaApplication
    }
}
function Import-PortablePackage {
    param([Parameter(Mandatory)][object]$Package)
    $modelsRoot = Expand-ManagerPath -Path `
        $script:ManagerConfig.Paths.Models
    $manifestRoot = Join-Path $modelsRoot 'manifests'
    $blobRoot = Join-Path $modelsRoot 'blobs'
    [IO.Directory]::CreateDirectory($manifestRoot) | Out-Null
    [IO.Directory]::CreateDirectory($blobRoot) | Out-Null
    Write-ManagerLog -Level INFO -Event IMPORT_START `
        -Message 'Manager.Log.ImportStarted' `
        -Data @{
            Model = $Package.Identity.ExactReference
            Package = $Package.PackagePath
        }
    foreach ($descriptor in $Package.Descriptors) {
        $source = Resolve-SafeChildPath -Root $Package.PackagePath `
            -RelativePath "blobs/$($descriptor.FileName)"
        $expectedHash = $descriptor.Digest.Substring(7)
        $destination = Join-Path $blobRoot $descriptor.FileName
        $sourceVerified = $false
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationHash = Get-FileSha256 -Path $destination
            if ($destinationHash -eq $expectedHash) {
                $sourceHash = Get-FileSha256 -Path $source
                if ($sourceHash -ne $expectedHash) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.PackageBlobHashMismatch' `
                        -Arguments @($descriptor.Digest))
                }
                $sourceVerified = $true
                Write-ManagerStatus -Level INFO `
                    -Message 'Manager.Import.ExistingBlob' `
                    -MessageArguments @(
                        $descriptor.FileName.Substring(0, 20)
                    )
            }
            else {
                $sourceHash = Get-FileSha256 -Path $source
                if ($sourceHash -ne $expectedHash) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.PackageBlobHashMismatch' `
                        -Arguments @($descriptor.Digest))
                }
                Remove-Item -LiteralPath $destination -Force
                Write-ManagerLog -Level WARN -Event BLOB_REMOVED `
                    -Message 'Manager.Log.CorruptBlobRemoved' `
                    -Data @{ Blob = $descriptor.Digest }
            }
        }
        if (-not $sourceVerified -and
            -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            $null = Copy-FileWithProgress -Source $source `
                -Destination $destination -ExpectedHash $expectedHash `
                -Activity ("$($Package.Identity.OllamaReference) | " +
                    $descriptor.FileName.Substring(0, 20))
        }
    }
    $manifestDestination = Resolve-SafeChildPath -Root $manifestRoot `
        -RelativePath $Package.Identity.ManifestRelativePath
    $manifestDirectory = Split-Path -Parent $manifestDestination
    [IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
    if (Test-Path -LiteralPath $manifestDestination -PathType Leaf) {
        $currentHash = Get-FileSha256 -Path $manifestDestination
        if ($currentHash -ne $Package.ManifestHash) {
            $sourceHash = Get-FileSha256 -Path $Package.ManifestPath
            if ($sourceHash -ne $Package.ManifestHash) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.ManifestHashMismatch' `
                    -Arguments @($Package.Identity.ExactReference))
            }
            Remove-Item -LiteralPath $manifestDestination -Force
            Write-ManagerLog -Level INFO -Event MANIFEST_REMOVED `
                -Message 'Manager.Log.StaleManifestRemoved' `
                -Data @{ Model = $Package.Identity.ExactReference }
        }
    }
    if (-not (Test-Path -LiteralPath $manifestDestination `
        -PathType Leaf)) {
        $null = Copy-FileWithProgress -Source $Package.ManifestPath `
            -Destination $manifestDestination `
            -ExpectedHash $Package.ManifestHash `
            -Activity (Get-LocalizedText `
                -Key 'Manager.Progress.Manifest' `
                -Arguments @($Package.Identity.OllamaReference))
    }
    Write-ManagerLog -Level INFO -Event IMPORT_SUCCESS `
        -Message 'Manager.Log.ImportCompleted' `
        -Data @{
            Model = $Package.Identity.ExactReference
            Manifest = $manifestDestination
        }
    Write-ManagerStatus -Level OK `
        -Message 'Manager.Import.Completed' `
        -MessageArguments @($Package.Identity.OllamaReference)
}
function Test-ManagerOllamaApi {
    $baseUri = 'http://{0}:{1}' -f `
        $script:ManagerConfig.Ollama.ApiHost,
        $script:ManagerConfig.Ollama.Port
    try {
        $response = Invoke-RestMethod -Uri "$baseUri/api/version" `
            -Method Get -TimeoutSec 5
        return -not [string]::IsNullOrWhiteSpace($response.version)
    }
    catch {
        Write-Verbose ('Ollama API denetimi basarisiz: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Get-ManagerOllamaOrigins {
    $origins = @($script:ManagerConfig.Ollama.AllowedOrigins)
    if ($script:ManagerConfig.Security.LanAccess) {
        $port = [int]$script:ManagerConfig.OpenWebUI.Port
        $hosts = @([Environment]::MachineName)
        $hosts += @(Get-NetIPAddress -AddressFamily IPv4 `
            -AddressState Preferred -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.SkipAsSource -and
                $_.IPAddress -notlike '127.*'
            } | Select-Object -ExpandProperty IPAddress)
        $origins += @($hosts | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            'http://{0}:{1}' -f $_, $port
        })
    }
    return @($origins | Sort-Object -Unique)
}
function Set-ManagerOllamaEnvironment {
    $origins = Get-ManagerOllamaOrigins
    $values = [ordered]@{
        OLLAMA_HOST = '{0}:{1}' -f `
            $script:ManagerConfig.Ollama.Host,
            $script:ManagerConfig.Ollama.Port
        OLLAMA_MODELS = Expand-ManagerPath -Path `
            $script:ManagerConfig.Paths.Models
        OLLAMA_ORIGINS = $origins -join ','
    }
    foreach ($entry in $values.GetEnumerator()) {
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
}
function Get-ManagerOllamaExecutable {
    $path = Join-Path (Expand-ManagerPath -Path `
        $script:ManagerConfig.Ollama.InstallPath) 'ollama.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return [IO.Path]::GetFullPath($path)
    }
    return $null
}
function Get-ManagerOllamaApplicationExecutable {
    $root = Expand-ManagerPath -Path `
        $script:ManagerConfig.Ollama.InstallPath
    $path = Join-Path $root 'ollama app.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return [IO.Path]::GetFullPath($path)
    }
    throw (Get-LocalizedText `
        -Key 'Ollama.Error.ApplicationExecutableMissing')
}
function Get-ManagerOllamaApplicationArgumentList {
    return @('--hide', '--fast-startup')
}
function New-ManagerOllamaApplicationStartParameters {
    param([Parameter(Mandatory)][string]$ApplicationPath)
    $fullPath = [IO.Path]::GetFullPath($ApplicationPath)
    return @{
        FilePath = $fullPath
        ArgumentList = @(Get-ManagerOllamaApplicationArgumentList)
        WorkingDirectory = Split-Path -Parent $fullPath
        PassThru = $true
    }
}
function Test-ManagerOllamaApplicationRunning {
    try {
        $application = Get-ManagerOllamaApplicationExecutable
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process `
            -ErrorAction SilentlyContinue)) {
            $path = [string]$process.ExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($path) -and
                [IO.Path]::GetFullPath($path).Equals(
                    $application,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                return $true
            }
        }
    }
    catch {
        Write-Verbose ('Ollama tray sureci denetlenemedi: {0}' -f `
            $_.Exception.Message)
    }
    return $false
}
function Start-ManagerOllamaApplication {
    Set-ManagerOllamaEnvironment
    $application = Get-ManagerOllamaApplicationExecutable
    $parameters = New-ManagerOllamaApplicationStartParameters `
        -ApplicationPath $application
    $process = Start-Process @parameters
    $process.Dispose()
}
function Start-OllamaForVerification {
    $apiReady = Test-ManagerOllamaApi
    $applicationRunning = Test-ManagerOllamaApplicationRunning
    if ($apiReady -and $applicationRunning) {
        return $true
    }
    $null = Suspend-OllamaApplication
    Start-ManagerOllamaApplication
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    do {
        if ((Test-ManagerOllamaApi) -and
            (Test-ManagerOllamaApplicationRunning)) {
            return $true
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $null = Suspend-OllamaApplication
    throw (Get-LocalizedText -Key 'Manager.Error.ApiNotReady')
}
function Assert-ManagerOllamaApplicationContracts {
    $application = [IO.Path]::GetFullPath(
        'C:\Fixture\Ollama\ollama app.exe'
    )
    $parameters = New-ManagerOllamaApplicationStartParameters `
        -ApplicationPath $application
    $arguments = @($parameters.ArgumentList)
    $startSource = (Get-Command Start-ManagerOllamaApplication `
        -ErrorAction Stop).Definition
    $verifySource = (Get-Command Start-OllamaForVerification `
        -ErrorAction Stop).Definition
    $resumeSource = (Get-Command Resume-OllamaApplication `
        -ErrorAction Stop).Definition
    if ([string]$parameters.FilePath -cne $application -or
        ($arguments -join '|') -cne '--hide|--fast-startup' -or
        $parameters.ContainsKey('NoNewWindow') -or
        $parameters.ContainsKey('RedirectStandardOutput') -or
        $parameters.ContainsKey('RedirectStandardError') -or
        $startSource -notmatch 'Get-ManagerOllamaApplicationExecutable' -or
        $verifySource -notmatch 'Start-ManagerOllamaApplication' -or
        ([regex]::Matches(
            $verifySource,
            'Suspend-OllamaApplication'
        )).Count -lt 2 -or
        $resumeSource -notmatch 'Start-ManagerOllamaApplication' -or
        ($startSource + $verifySource + $resumeSource) -match
            '\bserve\b' -or
        ($startSource + $verifySource + $resumeSource) -match
            'NoNewWindow') {
        throw 'Model yoneticisi Ollama tray sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ModelManager.OllamaTrayApplication'
    return $true
}
function Test-ImportedModelsWithApi {
    param([Parameter(Mandatory)][object[]]$Packages)
    if (-not $script:ManagerConfig.ModelTransfer.VerifyAfterImport) {
        return
    }
    if (-not (Start-OllamaForVerification)) {
        Write-ManagerStatus -Level WARN -Message `
            'Manager.Api.RuntimeMissing'
        Write-ManagerLog -Level WARN -Event API_VERIFY_SKIPPED `
            -Message 'Manager.Log.ApiRuntimeMissing' -Data $null
        return
    }
    $uri = 'http://{0}:{1}/api/show' -f `
        $script:ManagerConfig.Ollama.ApiHost,
        $script:ManagerConfig.Ollama.Port
    foreach ($package in $Packages) {
        $body = @{
            model = $package.Identity.OllamaReference
        } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri $uri -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Api.Verified' `
            -MessageArguments @($package.Identity.OllamaReference)
        Write-ManagerLog -Level INFO -Event API_VERIFY_SUCCESS `
            -Message 'Manager.Log.ApiVerified' `
            -Data @{ Model = $package.Identity.ExactReference }
    }
}
function Get-RemainingBlobReferences {
    $references = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $unsafeRoots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($modelsRoot in @(Get-NativeModelSearchDirectories)) {
        $manifestRoot = Join-Path $modelsRoot 'manifests'
        $blobRoot = [IO.Path]::GetFullPath(
            (Join-Path $modelsRoot 'blobs')
        )
        if (-not (Test-Path -LiteralPath $manifestRoot `
            -PathType Container)) {
            continue
        }
        try {
            $manifestFiles = @(
                Get-ChildItem -LiteralPath $manifestRoot `
                    -Recurse -File -ErrorAction Stop
            )
        }
        catch {
            $null = $unsafeRoots.Add($blobRoot)
            Write-ManagerLog -Level WARN `
                -Event DELETE_REFERENCE_SCAN `
                -Message 'Manager.Log.DeleteReferenceScanFailed' `
                -Data @{
                    Manifest = $manifestRoot
                    Error = $_.Exception.Message
                }
            continue
        }
        foreach ($file in $manifestFiles) {
            try {
                $manifest = Get-Content -LiteralPath $file.FullName `
                    -Raw -Encoding UTF8 | ConvertFrom-ManagerJson
                foreach ($descriptor in @(
                    Get-ManifestDescriptors -Manifest $manifest
                )) {
                    $null = $references.Add(
                        [IO.Path]::GetFullPath(
                            (Join-Path $blobRoot $descriptor.FileName)
                        )
                    )
                }
            }
            catch {
                $null = $unsafeRoots.Add($blobRoot)
                Write-ManagerLog -Level WARN `
                    -Event DELETE_REFERENCE_SCAN `
                    -Message 'Manager.Log.DeleteReferenceScanFailed' `
                    -Data @{
                        Manifest = $file.FullName
                        Error = $_.Exception.Message
                    }
            }
        }
    }
    return [pscustomobject]@{
        References = $references
        UnsafeBlobRoots = $unsafeRoots
    }
}
function Confirm-NativeModelDeletion {
    param([Parameter(Mandatory)][object[]]$Models)
    Write-ManagerSection -Title 'Manager.Section.Delete' `
        -TitleArguments @($Models.Count)
    foreach ($model in $Models) {
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key 'Manager.Delete.Item' `
            -Arguments @($model.Identity.OllamaReference)) `
            -Color Red
    }
    if ($ConfirmDelete) {
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.DeleteConfirmationRequired')
    }
    return Confirm-ManagerAction -Prompt (Get-LocalizedText `
        -Key 'Manager.Prompt.DeleteConfirm')
}
function Remove-NativeModels {
    param([Parameter(Mandatory)][object[]]$Models)
    $removedManifests = [Collections.Generic.List[string]]::new()
    foreach ($model in $Models) {
        if (-not (Test-Path -LiteralPath $model.ManifestPath `
            -PathType Leaf)) {
            continue
        }
        Remove-Item -LiteralPath $model.ManifestPath -Force
        $removedManifests.Add($model.ManifestPath)
    }
    if ($removedManifests.Count -ne $Models.Count) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.DeleteManifestIncomplete')
    }
    $remaining = Get-RemainingBlobReferences
    $deletedBlobs = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $freedBytes = [long]0
    foreach ($model in $Models) {
        $blobRoot = [IO.Path]::GetFullPath($model.BlobRoot)
        if ($remaining.UnsafeBlobRoots.Contains($blobRoot)) {
            Write-ManagerStatus -Level WARN `
                -Message 'Manager.Delete.BlobCleanupSkipped' `
                -MessageArguments @($blobRoot)
            Write-ManagerLog -Level WARN `
                -Event DELETE_BLOB_CLEANUP_SKIPPED `
                -Message 'Manager.Log.DeleteBlobCleanupSkipped' `
                -Data @{ Root = $blobRoot }
        }
        else {
            foreach ($descriptor in $model.Descriptors) {
                $blobPath = [IO.Path]::GetFullPath(
                    (Join-Path $blobRoot $descriptor.FileName)
                )
                if ($remaining.References.Contains($blobPath) -or
                    -not (Test-Path -LiteralPath $blobPath `
                        -PathType Leaf) -or
                    -not $deletedBlobs.Add($blobPath)) {
                    continue
                }
                $freedBytes += (Get-Item -LiteralPath $blobPath).Length
                Remove-Item -LiteralPath $blobPath -Force
            }
        }
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Delete.ModelCompleted' `
            -MessageArguments @($model.Identity.OllamaReference)
        Write-ManagerLog -Level INFO -Event MODEL_DELETE `
            -Message 'Manager.Log.ModelDeleted' `
            -Data @{
                Model = $model.Identity.ExactReference
                Manifest = $model.ManifestPath
            }
    }
    Write-ManagerStatus -Level OK `
        -Message 'Manager.Delete.Completed' `
        -MessageArguments @(
            $Models.Count,
            (Format-ByteSize -Bytes $freedBytes)
        )
    Write-ManagerLog -Level INFO -Event DELETE_COMPLETED `
        -Message 'Manager.Log.DeleteCompleted' `
        -Data @{
            Models = $Models.Count
            Blobs = $deletedBlobs.Count
            FreedBytes = $freedBytes
        }
}
function Get-PackageDisplayName {
    param([Parameter(Mandatory)][object]$Item)
    if ($Item.IsValid) {
        return $Item.Package.Identity.OllamaReference
    }
    return [IO.Path]::GetFileName($Item.PackagePath)
}
function Confirm-PackageDeletion {
    param([Parameter(Mandatory)][object[]]$Packages)
    Write-ManagerSection -Title 'Manager.Section.PackageDelete' `
        -TitleArguments @($Packages.Count)
    foreach ($item in $Packages) {
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key 'Manager.PackageDelete.Item' `
            -Arguments @(
                (Get-PackageDisplayName -Item $item),
                $item.PackagePath
            )) -Color Red
    }
    if ($ConfirmDelete) {
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.DeleteConfirmationRequired')
    }
    return Confirm-ManagerAction -Prompt (Get-LocalizedText `
        -Key 'Manager.Prompt.PackageDeleteConfirm')
}
function Assert-PackageDeletionPath {
    param([Parameter(Mandatory)][string]$PackagePath)
    $fullPath = [IO.Path]::GetFullPath($PackagePath)
    foreach ($configuredRoot in @(
        $script:ManagerConfig.ModelTransfer.ImportSearchDirectories
    )) {
        $root = Expand-ManagerPath -Path ([string]$configuredRoot)
        $root = $root.TrimEnd('\')
        $prefix = $root + '\'
        if ($fullPath.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $fullPath
        }
    }
    throw (Get-LocalizedText `
        -Key 'Manager.Error.PackageDeleteOutsideRoot' `
        -Arguments @($PackagePath))
}
function Remove-PortablePackages {
    param([Parameter(Mandatory)][object[]]$Packages)
    $removed = 0
    foreach ($item in $Packages) {
        $path = Assert-PackageDeletionPath `
            -PackagePath $item.PackagePath
        $directory = Get-Item -LiteralPath $path -Force
        if (($directory.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.PackageDeleteReparsePoint' `
                -Arguments @($path))
        }
        $name = Get-PackageDisplayName -Item $item
        Remove-Item -LiteralPath $path -Recurse -Force
        $removed++
        Write-ManagerStatus -Level OK `
            -Message 'Manager.PackageDelete.ItemCompleted' `
            -MessageArguments @($name)
        Write-ManagerLog -Level INFO -Event PACKAGE_DELETE `
            -Message 'Manager.Log.PackageDeleted' `
            -Data @{ Model = $name; Package = $path }
    }
    Write-ManagerStatus -Level OK `
        -Message 'Manager.PackageDelete.Completed' `
        -MessageArguments @($removed)
}
function Test-ManagerModelReference {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Expected
    )
    if ($Candidate -ieq $Expected) {
        return $true
    }
    return $Candidate -ieq `
        "registry.ollama.ai/library/$Expected"
}
function Get-ManagerCatalogEntries {
    $installed = @(Get-NativeModels)
    $packages = @(Get-PackageSummaries | Where-Object IsValid)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($model in @($script:ManagerConfig.Models.Catalog)) {
        $native = $installed | Where-Object {
            $_.IsReady -and (
                Test-ManagerModelReference `
                    -Candidate $_.Identity.OllamaReference `
                    -Expected $model.Name
            )
        } | Select-Object -First 1
        $package = $packages | Where-Object {
            Test-ManagerModelReference `
                -Candidate $_.Package.Identity.OllamaReference `
                -Expected $model.Name
        } | Select-Object -First 1
        $entries.Add([pscustomobject]@{
            Model = $model
            Native = $native
            Package = $package
            IsInstalled = $null -ne $native
        })
    }
    return $entries.ToArray()
}
function Show-ManagerCatalog {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )
    Write-ManagerSection -Title 'Manager.Section.DownloadCatalog'
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]
        $source = 'Manager.Download.SourceInternet'
        $color = 'Gray'
        if ($entry.IsInstalled) {
            $source = 'Manager.Download.SourceInstalled'
            $color = 'Green'
        }
        elseif ($null -ne $entry.Package) {
            $source = 'Manager.Download.SourceLocal'
            $color = 'Cyan'
        }
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key 'Manager.Download.CatalogRow' `
            -Arguments @(
                ($index + 1),
                $entry.Model.Name,
                $entry.Model.DownloadSizeGB,
                (Get-LocalizedText -Key $source)
            )) -Color $color
    }
    Write-ManagerRule
}
function Resolve-ManagerCatalogSelection {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )
    if ($All) {
        return $Entries
    }
    $interactive = [string]::IsNullOrWhiteSpace($ModelSelection)
    while ($true) {
        $selection = $ModelSelection
        if ($interactive) {
            $selection = Read-ManagerInput -Prompt (Get-LocalizedText `
                -Key 'Manager.Prompt.DownloadModels')
        }
        if ($selection -eq '0') {
            return @()
        }
        if ([string]::IsNullOrWhiteSpace($selection)) {
            if (-not $interactive) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.ModelSelectionRequired')
            }
            Write-ManagerStatus -Level WARN `
                -Message 'Common.Selection.Invalid'
            continue
        }
        if ($selection -ieq 'A') {
            return $Entries
        }
        try {
            if ($selection.Trim().StartsWith('-')) {
                $indices = @(Resolve-WinlamaIndexSelection `
                    -Value $selection -Count $Entries.Count)
                return @($indices | ForEach-Object {
                    $Entries[$_ - 1]
                })
            }
            $selected = [Collections.Generic.List[object]]::new()
            $names = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($token in $selection.Split(',')) {
                $value = $token.Trim()
                $number = 0
                $entry = $null
                if ([int]::TryParse($value, [ref]$number)) {
                    if ($number -lt 1 -or $number -gt $Entries.Count) {
                        throw (Get-LocalizedText `
                            -Key 'Manager.Error.ModelIndexInvalid' `
                            -Arguments @($value))
                    }
                    $entry = $Entries[$number - 1]
                }
                else {
                    $entry = $Entries | Where-Object {
                        $_.Model.Name -ieq $value
                    } | Select-Object -First 1
                }
                if ($null -eq $entry) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.ModelNotFound' `
                        -Arguments @($value))
                }
                if ($names.Add($entry.Model.Name)) {
                    $selected.Add($entry)
                }
            }
            return $selected.ToArray()
        }
        catch {
            if (-not $interactive) {
                throw
            }
            Write-ManagerStatus -Level WARN `
                -Message $_.Exception.Message
        }
    }
}
function Resolve-ManagerDownloadSourceSelection {
    param([AllowEmptyString()][string]$Value = '')
    if ($Value -ceq 'YEREL') {
        return 'Local'
    }
    if ($Value -ceq 'INTERNET') {
        return 'Internet'
    }
    if ($Value -ceq '0') {
        return 'Cancel'
    }
    return $null
}
function Get-ManagerDownloadSource {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )
    if (@($Entries | Where-Object { $null -ne $_.Package }).Count `
        -eq 0) {
        return 'Internet'
    }
    if ($Action -ne 'Menu') {
        return 'Local'
    }
    while ($true) {
        $answer = Read-ManagerInput -Prompt (Get-LocalizedText `
            -Key 'Manager.Prompt.DownloadSource')
        $selection = Resolve-ManagerDownloadSourceSelection -Value $answer
        if ($null -ne $selection) {
            return $selection
        }
        Write-ManagerStatus -Level WARN `
            -Message 'Common.Selection.Invalid'
    }
}
function Test-ManagerModelInstalled {
    param([Parameter(Mandatory)][string]$Name)
    if (Test-ManagerOllamaApi) {
        $uri = 'http://{0}:{1}/api/show' -f `
            $script:ManagerConfig.Ollama.ApiHost,
            $script:ManagerConfig.Ollama.Port
        try {
            $body = @{ model = $Name } | ConvertTo-Json -Compress
            $response = Invoke-RestMethod -Uri $uri -Method Post `
                -ContentType 'application/json' -Body $body `
                -TimeoutSec 30
            return $null -ne $response
        }
        catch {
            Write-Verbose ('Ollama API model testi basarisiz: {0}' -f `
                $_.Exception.Message)
        }
    }
    return $null -ne (@(Get-NativeModels) | Where-Object {
        $_.IsReady -and (
            Test-ManagerModelReference `
                -Candidate $_.Identity.OllamaReference `
                -Expected $Name
        )
    } | Select-Object -First 1)
}
function Assert-ManagerDownloadDiskSpace {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $modelsPath = Expand-ManagerPath -Path `
        $script:ManagerConfig.Paths.Models
    $root = [IO.Path]::GetPathRoot($modelsPath)
    $drive = [IO.DriveInfo]::new($root)
    $requiredGB = (
        $Model.DownloadSizeGB + $Model.WorkingSpaceGB
    ) * (
        1 + $script:ManagerConfig.Models.SafetyBufferPercent / 100.0
    )
    $freeGB = $drive.AvailableFreeSpace / 1GB
    if ($freeGB -lt $requiredGB) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.DownloadDiskInsufficient' `
            -Arguments @(
                $Model.Name,
                [math]::Ceiling($requiredGB),
                [math]::Round($freeGB, 2)
            ))
    }
}
function Invoke-ManagerInternetDownload {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    if (Test-ManagerModelInstalled -Name $Model.Name) {
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Download.AlreadyInstalled' `
            -MessageArguments @($Model.Name)
        return
    }
    Assert-ManagerDownloadDiskSpace -Model $Model
    Set-ManagerOllamaEnvironment
    if (-not (Start-OllamaForVerification)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ApiRuntimeMissing')
    }
    $ollama = Get-ManagerOllamaExecutable
    if ([string]::IsNullOrWhiteSpace($ollama)) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.OllamaExecutableMissing')
    }
    $delays = @($script:ManagerConfig.Network.RetryBackoffSeconds)
    $lastError = $null
    for ($attempt = 0; $attempt -le $delays.Count; $attempt++) {
        try {
            Write-ManagerStatus -Level INFO `
                -Message 'Manager.Download.Starting' `
                -MessageArguments @($Model.Name)
            Write-ManagerLog -Level INFO -Event DOWNLOAD_START `
                -Message 'Manager.Log.DownloadStarted' `
                -Data @{ Model = $Model.Name; Attempt = $attempt + 1 }
            $timeout = [int](
                $script:ManagerConfig.Network.DownloadTimeoutSeconds
            )
            $process = $null
            $exitCode = -1
            try {
                $process = Start-Process -FilePath $ollama `
                    -ArgumentList @('pull', $Model.Name) `
                    -WorkingDirectory (Split-Path -Parent $ollama) `
                    -NoNewWindow -PassThru
                if (-not $process.WaitForExit($timeout * 1000)) {
                    Stop-Process -Id $process.Id -Force `
                        -ErrorAction SilentlyContinue
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.DownloadTimeout' `
                        -Arguments @($Model.Name, $timeout))
                }
                $exitCode = $process.ExitCode
            }
            finally {
                if ($null -ne $process) {
                    $process.Dispose()
                }
            }
            if ($exitCode -ne 0) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.DownloadFailed' `
                    -Arguments @($Model.Name, $exitCode))
            }
            if (-not (Test-ManagerModelInstalled -Name $Model.Name)) {
                throw (Get-LocalizedText `
                    -Key 'Manager.Error.DownloadVerificationFailed' `
                    -Arguments @($Model.Name))
            }
            Write-ManagerStatus -Level OK `
                -Message 'Manager.Download.Completed' `
                -MessageArguments @($Model.Name)
            Write-ManagerLog -Level INFO -Event DOWNLOAD_SUCCESS `
                -Message 'Manager.Log.DownloadCompleted' `
                -Data @{ Model = $Model.Name }
            return
        }
        catch {
            $lastError = $_.Exception
            if ($attempt -lt $delays.Count) {
                Write-ManagerStatus -Level WARN `
                    -Message 'Manager.Download.Retrying' `
                    -MessageArguments @(
                        $Model.Name,
                        $delays[$attempt]
                    )
                Start-Sleep -Seconds $delays[$attempt]
            }
        }
    }
    Write-ManagerLog -Level ERROR -Event DOWNLOAD_FAILED `
        -Message 'Manager.Log.DownloadFailed' `
        -Data @{ Model = $Model.Name;
            Error = $lastError.ToString() }
    throw $lastError
}
function Invoke-DownloadAction {
    $entries = @(Get-ManagerCatalogEntries)
    Show-ManagerCatalog -Entries $entries
    $selected = @(Resolve-ManagerCatalogSelection -Entries $entries)
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Download.Cancelled'
        return
    }
    $pending = @($selected | Where-Object { -not $_.IsInstalled })
    foreach ($entry in @($selected | Where-Object IsInstalled)) {
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Download.AlreadyInstalled' `
            -MessageArguments @($entry.Model.Name)
    }
    if ($pending.Count -eq 0) {
        return
    }
    $source = Get-ManagerDownloadSource -Entries $pending
    if ($source -eq 'Cancel') {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Download.Cancelled'
        return
    }
    $localEntries = @()
    $internetEntries = $pending
    if ($source -eq 'Local') {
        $localEntries = @($pending | Where-Object {
            $null -ne $_.Package
        })
        $internetEntries = @($pending | Where-Object {
            $null -eq $_.Package
        })
    }
    if ($localEntries.Count -gt 0) {
        $ollamaState = @()
        try {
            $ollamaState = @(Suspend-OllamaApplication)
            foreach ($entry in $localEntries) {
                Import-PortablePackage `
                    -Package $entry.Package.Package
            }
        }
        finally {
            Resume-OllamaApplication -States $ollamaState
        }
        $importedPackages = @($localEntries | ForEach-Object {
            $_.Package.Package
        })
        Test-ImportedModelsWithApi -Packages $importedPackages
    }
    foreach ($entry in $internetEntries) {
        Invoke-ManagerInternetDownload -Model $entry.Model
    }
    Write-ManagerStatus -Level OK `
        -Message 'Manager.Download.AllCompleted' `
        -MessageArguments @($pending.Count)
    Write-ManagerLog -Level INFO -Event DOWNLOAD_BATCH_SUCCESS `
        -Message 'Manager.Log.DownloadBatchCompleted' `
        -Data @{ Count = $pending.Count; Source = $source }
}
function Invoke-ListAction {
    $models = @(Get-NativeModels)
    Show-NativeModels -Models $models
    Write-ManagerLog -Level INFO -Event LIST `
        -Message 'Manager.Log.ModelsListed' `
        -Data @{ Count = $models.Count }
}
function Invoke-PackageListAction {
    $summaries = @(Get-PackageSummaries)
    Show-Packages -Packages $summaries
    Write-ManagerLog -Level INFO -Event PACKAGE_LIST `
        -Message 'Manager.Log.PackagesListed' `
        -Data @{ Count = $summaries.Count }
}
function Invoke-ExportAction {
    $models = @(Get-NativeModels)
    Show-NativeModels -Models $models
    $selected = @(Resolve-ModelSelection -Models $models)
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Export.Cancelled'
        return
    }
    Write-ManagerSection -Title 'Manager.Section.Export' `
        -TitleArguments @($selected.Count)
    foreach ($model in $selected) {
        $null = Export-NativeModel -Model $model
    }
}
function Invoke-VerifyAction {
    $summaries = @(Get-PackageSummaries)
    Show-Packages -Packages $summaries
    $selected = @(Resolve-PackageSelection -Packages $summaries)
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Verify.Cancelled'
        return
    }
    Write-ManagerSection -Title 'Manager.Section.Verify' `
        -TitleArguments @($selected.Count)
    foreach ($item in $selected) {
        $package = Read-PortablePackage `
            -PackagePath $item.PackagePath -VerifyHashes
        Write-ManagerStatus -Level OK `
            -Message 'Manager.Verify.Completed' `
            -MessageArguments @($package.Identity.OllamaReference)
        Write-ManagerLog -Level INFO -Event PACKAGE_VERIFY_SUCCESS `
            -Message 'Manager.Log.PackageVerified' `
            -Data @{ Model = $package.Identity.ExactReference;
                Package = $package.PackagePath }
    }
}
function Invoke-ImportAction {
    $summaries = @(Get-PackageSummaries)
    Show-Packages -Packages $summaries
    $selectedItems = @(Resolve-PackageSelection -Packages $summaries)
    if ($selectedItems.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Import.Cancelled'
        return
    }
    $packages = @($selectedItems | ForEach-Object { $_.Package })
    Write-ManagerSection -Title 'Manager.Section.Import' `
        -TitleArguments @($packages.Count)
    $ollamaState = @()
    try {
        $ollamaState = @(Suspend-OllamaApplication)
        foreach ($package in $packages) {
            Import-PortablePackage -Package $package
        }
        Test-ImportedModelsWithApi -Packages $packages
    }
    finally {
        Resume-OllamaApplication -States $ollamaState
    }
}
function Invoke-DeleteAction {
    $models = @(Get-NativeModels)
    Show-NativeModels -Models $models
    $selected = @(
        Resolve-ModelSelection -Models $models `
            -RequireExplicit -IncludeIncomplete
    )
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Delete.Cancelled'
        return
    }
    if (-not (Confirm-NativeModelDeletion -Models $selected)) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.Delete.Cancelled'
        return
    }
    $ollamaState = @()
    try {
        $ollamaState = @(Suspend-OllamaApplication)
        Remove-NativeModels -Models $selected
    }
    finally {
        Resume-OllamaApplication -States $ollamaState
    }
}
function Invoke-PackageDeleteAction {
    $summaries = @(Get-PackageSummaries)
    Show-Packages -Packages $summaries
    $selected = @(
        Resolve-PackageSelection -Packages $summaries `
            -RequireExplicit -IncludeInvalid
    )
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.PackageDelete.Cancelled'
        return
    }
    if (-not (Confirm-PackageDeletion -Packages $selected)) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.PackageDelete.Cancelled'
        return
    }
    Remove-PortablePackages -Packages $selected
}
function Get-ComfyUIModelsRoot {
    return Expand-ManagerPath -Path `
        $script:ManagerConfig.ComfyUI.ModelsPath
}
function Get-ComfyUIModelDirectoryName {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $name = [string](Get-JsonValue -InputObject $Model `
        -Name LocalDirectory -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($name)) {
        $asset = @(Get-ComfyUIModelAssets -Model $Model) |
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
function Get-ComfyUIModelFiles {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }
    $extensions = @(
        '.bin', '.ckpt', '.gguf', '.onnx', '.pt', '.pth',
        '.safetensors'
    )
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File `
        -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -iin $extensions -and $_.Length -gt 0
        })
}
function Get-ComfyUIModelSourceRoots {
    $roots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $PSScriptRoot 'Models'))
    $installation = $script:ManagerConfig.PSObject.Properties[
        'Installation'
    ]
    if ($null -ne $installation) {
        $source = [string](Get-JsonValue `
            -InputObject $installation.Value -Name Source `
            -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            $candidates.Add((Join-Path $source 'Models'))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $null = $roots.Add([IO.Path]::GetFullPath($candidate))
        }
    }
    return @($roots)
}
function Find-ComfyUILocalModelDirectory {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $name = Get-ComfyUIModelDirectoryName -Model $Model
    foreach ($root in @(Get-ComfyUIModelSourceRoots)) {
        $path = Join-Path $root $name
        if (@(Get-ComfyUIModelFiles -Path $path).Count -gt 0) {
            return [IO.Path]::GetFullPath($path)
        }
    }
    return $null
}
function Get-ComfyUIEffectiveCatalog {
    $catalog = [Collections.Generic.List[object]]::new()
    $knownDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($model in @($script:ManagerConfig.ComfyUI.Catalog)) {
        $catalog.Add($model)
        $null = $knownDirectories.Add(
            (Get-ComfyUIModelDirectoryName -Model $model)
        )
    }
    $roots = @(Get-ComfyUIModelSourceRoots) + @(Get-ComfyUIModelsRoot)
    foreach ($root in @($roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        $rootPath = [IO.Path]::GetFullPath($root).TrimEnd('\')
        foreach ($family in Get-ChildItem -LiteralPath $root `
            -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
            $candidates = @(Get-ChildItem -LiteralPath $family.FullName `
                -Directory -ErrorAction SilentlyContinue | Where-Object {
                    @(Get-ComfyUIModelFiles `
                        -Path $_.FullName).Count -gt 0
                })
            if ($candidates.Count -eq 0 -and
                @(Get-ComfyUIModelFiles -Path $family.FullName).Count -gt 0) {
                $candidates = @($family)
            }
            foreach ($directory in $candidates) {
                $relativeDirectory = $directory.FullName.Substring(
                    $rootPath.Length
                ).TrimStart('\')
                if ($knownDirectories.Contains($relativeDirectory)) {
                    continue
                }
                $files = @(Get-ComfyUIModelFiles -Path $directory.FullName)
                $type = if ($relativeDirectory -match `
                '(?i)wan|video|ltx|hunyuan') {
                'VideoGeneration'
            }
                elseif ($relativeDirectory -match `
                '(?i)flux|image|sdxl|stable') {
                'ImageGeneration'
            }
                else {
                'LocalModel'
            }
                $catalog.Add([pscustomobject][ordered]@{
                    Name = $relativeDirectory.Replace('\', '-')
                    LocalDirectory = $relativeDirectory
                    Type = $type
                    Format = 'local-directory'
                    DownloadSizeGB = [math]::Round(
                        (($files | Measure-Object Length -Sum).Sum / 1GB),
                        2
                    )
                    WorkingSpaceGB = 0.0
                    License = ''
                    Description = Get-LocalizedText `
                        -Key 'Installer.ComfyUI.DiscoveredDescription'
                    LocalOnly = $true
                    Assets = @()
                })
                $null = $knownDirectories.Add($relativeDirectory)
            }
        }
    }
    return $catalog.ToArray()
}
function Get-ComfyUIModelAssets {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $assetsProperty = $Model.PSObject.Properties['Assets']
    if ($null -ne $assetsProperty -and
        @($assetsProperty.Value).Count -gt 0) {
        return @($assetsProperty.Value)
    }
    $uri = [string](Get-JsonValue -InputObject $Model `
        -Name Uri -DefaultValue '')
    $localPath = [string](Get-JsonValue -InputObject $Model `
        -Name LocalPath -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($uri) -or
        [string]::IsNullOrWhiteSpace($localPath)) {
        return @()
    }
    $fileName = [IO.Path]::GetFileName(([uri]$uri).AbsolutePath)
    return @([pscustomobject]@{
        RelativePath = Join-Path $localPath $fileName
        Uri = $uri
        Sha256 = ''
        SizeGB = [double]$Model.DownloadSizeGB
    })
}
function Get-ComfyUIModelAssetPath {
    param([Parameter(Mandatory)][pscustomobject]$Asset)
    $root = Get-ComfyUIModelsRoot
    return Resolve-SafeChildPath -Root $root `
        -RelativePath ([string]$Asset.RelativePath)
}
function Test-ComfyUIModelInstalled {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [switch]$VerifyHash
    )
    $root = Get-ComfyUIModelsRoot
    $name = Get-ComfyUIModelDirectoryName -Model $Model
    $directory = Join-Path $root $name
    $marker = Join-Path $directory '.winlama-local-model'
    if ((Test-Path -LiteralPath $marker -PathType Leaf) -and
        @(Get-ComfyUIModelFiles -Path $directory).Count -gt 0) {
        return $true
    }
    $assets = @(Get-ComfyUIModelAssets -Model $Model)
    if ($assets.Count -eq 0) {
        return @(Get-ComfyUIModelFiles -Path $directory).Count -gt 0
    }
    foreach ($asset in $assets) {
        $path = Get-ComfyUIModelAssetPath -Asset $asset
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        if ((Get-Item -LiteralPath $path).Length -eq 0) {
            return $false
        }
        $expectedHash = [string](Get-JsonValue `
            -InputObject $asset -Name Sha256 -DefaultValue '')
        if ($VerifyHash -and
            -not [string]::IsNullOrWhiteSpace($expectedHash) -and
            (Get-FileSha256 -Path $path) -ne
                $expectedHash.ToLowerInvariant()) {
            return $false
        }
    }
    return $true
}
function Get-ComfyUICatalogEntries {
    $comfyUI = $script:ManagerConfig.ComfyUI
    if ($null -eq $comfyUI -or
        $null -eq $comfyUI.PSObject.Properties['Catalog']) {
        return @()
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($model in @(Get-ComfyUIEffectiveCatalog)) {
        $source = Find-ComfyUILocalModelDirectory -Model $model
        $entries.Add([pscustomobject]@{
            Model = $model
            IsLocal = Test-ComfyUIModelInstalled -Model $model
            SourcePath = $source
        })
    }
    return $entries.ToArray()
}
function Show-ComfyUICatalog {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )
    Write-ManagerSection -Title 'Manager.Section.ComfyUIModels'
    if ($Entries.Count -eq 0) {
        Write-ManagerStatus -Level WARN -Message 'Manager.ComfyUI.NoneFound'
        return
    }
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]
        $typeKey = if ($entry.Model.Type -eq 'ImageGeneration') {
            'Manager.ComfyUI.TypeImage'
        }
        elseif ($entry.Model.Type -eq 'VideoGeneration') {
            'Manager.ComfyUI.TypeVideo'
        }
        else {
            'Manager.ComfyUI.TypeLocal'
        }
        $readyProperty = $entry.Model.PSObject.Properties['InstallReady']
        $installReady = $null -eq $readyProperty -or
            [bool]$readyProperty.Value
        $statusKey = if (-not $installReady) {
            'Manager.ComfyUI.UnsupportedArchive'
        }
        elseif ($entry.IsLocal) {
            'Manager.ComfyUI.Installed'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($entry.SourcePath)) {
            'Manager.ComfyUI.LocalAvailable'
        } else {
            'Manager.ComfyUI.NotInstalled'
        }
        $color = if (-not $installReady) {
            'Yellow'
        }
        elseif ($entry.IsLocal -or
            -not [string]::IsNullOrWhiteSpace($entry.SourcePath)) {
            'Green'
        }
        else {
            'Gray'
        }
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key 'Manager.ComfyUI.CatalogRow' `
            -Arguments @(
                ($index + 1),
                $entry.Model.Name,
                $entry.Model.DownloadSizeGB,
                ('{0} | {1}' -f `
                    (Get-LocalizedText -Key $typeKey),
                    (Get-LocalizedText -Key $statusKey))
            )) -Color $color
    }
    Write-ManagerRule
}
function Invoke-ComfyUIListAction {
    $entries = @(Get-ComfyUICatalogEntries)
    Show-ComfyUICatalog -Entries $entries
}
function Test-ComfyUILocalModelCopied {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][string]$Source
    )
    if (@(Get-ComfyUIModelAssets -Model $Model).Count -gt 0) {
        return Test-ComfyUIModelInstalled -Model $Model -VerifyHash
    }
    $destination = Join-Path (Get-ComfyUIModelsRoot) `
        (Get-ComfyUIModelDirectoryName -Model $Model)
    foreach ($file in @(Get-ComfyUIModelFiles -Path $Source)) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $destination $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-Item -LiteralPath $target).Length -ne $file.Length) {
            return $false
        }
    }
    return $true
}
function Copy-ComfyUILocalModel {
    param(
        [Parameter(Mandatory)][pscustomobject]$Model,
        [Parameter(Mandatory)][string]$Source
    )
    if (@(Get-ComfyUIModelAssets -Model $Model).Count -gt 0) {
        $null = Install-ComfyUIModelPayload -Model $Model
        if (-not (Test-ComfyUIModelInstalled `
            -Model $Model -VerifyHash)) {
            throw (Get-LocalizedText `
                -Key 'Manager.ComfyUI.VerificationFailed' `
                -Arguments @($Model.Name))
        }
        return
    }
    $root = Get-ComfyUIModelsRoot
    $destination = Join-Path $root `
        (Get-ComfyUIModelDirectoryName -Model $Model)
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\') -ieq
        [IO.Path]::GetFullPath($destination).TrimEnd('\')) {
        return
    }
    $requiredBytes = 0L
    foreach ($file in @(Get-ComfyUIModelFiles -Path $Source)) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $destination $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-Item -LiteralPath $target).Length -ne $file.Length) {
            $requiredBytes += $file.Length
        }
    }
    $driveRoot = [IO.Path]::GetPathRoot($root)
    $freeBytes = [IO.DriveInfo]::new($driveRoot).AvailableFreeSpace
    if ($requiredBytes -gt $freeBytes) {
        throw (Get-LocalizedText `
            -Key 'Installer.ComfyUI.LocalDiskInsufficient' `
            -Arguments @(
                $Model.Name,
                [math]::Ceiling($requiredBytes / 1GB),
                [math]::Round($freeBytes / 1GB, 2)
            ))
    }
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $arguments = @(
        $Source, $destination, '/E', '/COPY:DAT', '/DCOPY:DAT',
        '/R:2', '/W:2', '/XJ', '/J', '/NP', '/NFL', '/NDL',
        '/NJH', '/NJS'
    )
    & robocopy.exe @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8 -or
        -not (Test-ComfyUILocalModelCopied `
            -Model $Model -Source $Source)) {
        throw (Get-LocalizedText `
            -Key 'Installer.ComfyUI.LocalCopyFailed' `
            -Arguments @($Model.Name, $exitCode))
    }
    [IO.File]::WriteAllText(
        (Join-Path $destination '.winlama-local-model'),
        [string]$Model.Name,
        [Text.UTF8Encoding]::new($false)
    )
}
function Assert-ComfyUIDownloadDiskSpace {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $root = Get-ComfyUIModelsRoot
    $driveRoot = [IO.Path]::GetPathRoot($root)
    $drive = [IO.DriveInfo]::new($driveRoot)
    $requiredGB = 0.0
    foreach ($asset in @(Get-ComfyUIModelAssets -Model $Model)) {
        $path = Get-ComfyUIModelAssetPath -Asset $asset
        $requiresDownload = -not (
            Test-Path -LiteralPath $path -PathType Leaf
        )
        $expectedHash = [string](Get-JsonValue `
            -InputObject $asset -Name Sha256 -DefaultValue '')
        if (-not $requiresDownload -and
            -not [string]::IsNullOrWhiteSpace($expectedHash) -and
            (Get-FileSha256 -Path $path) -ne
                $expectedHash.ToLowerInvariant()) {
            $requiresDownload = $true
        }
        if ($requiresDownload) {
            $requiredGB += [double](Get-JsonValue `
                -InputObject $asset -Name SizeGB -DefaultValue 0)
        }
    }
    $requiredGB *= 1 + (
        $script:ManagerConfig.Models.SafetyBufferPercent / 100.0
    )
    $freeGB = $drive.AvailableFreeSpace / 1GB
    if ($freeGB -lt $requiredGB) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.DownloadDiskInsufficient' `
            -Arguments @(
                $Model.Name,
                [math]::Ceiling($requiredGB),
                [math]::Round($freeGB, 2)
            ))
    }
}
function Install-ComfyUIModelPayload {
    param([Parameter(Mandatory)][pscustomobject]$Model)
    $downloaded = 0
    foreach ($asset in @(Get-ComfyUIModelAssets -Model $Model)) {
        $target = Get-ComfyUIModelAssetPath -Asset $asset
        $expectedHash = [string](Get-JsonValue `
            -InputObject $asset -Name Sha256 -DefaultValue '')
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            if ([string]::IsNullOrWhiteSpace($expectedHash) -or
                (Get-FileSha256 -Path $target) -eq
                    $expectedHash.ToLowerInvariant()) {
                continue
            }
        }
        $packageAsset = $null
        foreach ($packageRoot in @(Get-ComfyUIModelSourceRoots)) {
            $candidate = Resolve-SafeChildPath -Root $packageRoot `
                -RelativePath ([string]$asset.RelativePath)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $packageAsset = $candidate
                break
            }
        }
        if ($null -ne $packageAsset) {
            if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and
                (Get-FileSha256 -Path $packageAsset) -ne
                    $expectedHash.ToLowerInvariant()) {
                throw (Get-LocalizedText `
                    -Key 'Manager.ComfyUI.HashMismatch' `
                    -Arguments @($Model.Name, $asset.RelativePath))
            }
            [IO.Directory]::CreateDirectory(
                (Split-Path -Parent $target)
            ) | Out-Null
            $temporary = '{0}.{1}.copy' -f $target, $PID
            try {
                Copy-Item -LiteralPath $packageAsset `
                    -Destination $temporary -Force
                Move-Item -LiteralPath $temporary `
                    -Destination $target -Force
                $downloaded++
                continue
            }
            finally {
                Remove-Item -LiteralPath $temporary -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        $uri = [uri]$asset.Uri
        if ($uri.Scheme -ne 'https') {
            throw (Get-LocalizedText `
                -Key 'Manager.ComfyUI.InsecureUri' `
                -Arguments @($uri.AbsoluteUri))
        }
        [IO.Directory]::CreateDirectory(
            (Split-Path -Parent $target)
        ) | Out-Null
        $temporary = '{0}.{1}.download' -f $target, $PID
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -Uri $uri.AbsoluteUri `
                -OutFile $temporary -UseBasicParsing `
                -TimeoutSec ([int]$script:ManagerConfig.
                    Network.DownloadTimeoutSeconds)
            if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                $actualHash = Get-FileSha256 -Path $temporary
                if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.ComfyUI.HashMismatch' `
                        -Arguments @($Model.Name, $asset.RelativePath))
                }
            }
            Move-Item -LiteralPath $temporary `
                -Destination $target -Force
            $downloaded++
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return $downloaded
}
function Resolve-ComfyUISelection {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [switch]$Delete
    )
    if ($All) {
        return $Entries
    }
    $interactive = $Action -eq 'Menu'
    $value = $ModelSelection
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            if (-not $interactive) {
                return @()
            }
            $key = if ($Delete) {
                'Manager.ComfyUI.SelectDeleteModels'
            }
            else {
                'Manager.ComfyUI.SelectModels'
            }
            $value = Read-ManagerInput -Prompt (
                Get-LocalizedText -Key $key
            )
        }
        if ($value -eq '0') {
            return @()
        }
        try {
            $numericSelection = $value -ieq 'A' -or
                $value.Trim().StartsWith('-') -or
                $value -match '^\s*\d+(?:\s*[,.;]\s*\d+)*\s*$'
            if ($numericSelection) {
                $indices = @(Resolve-WinlamaIndexSelection `
                    -Value $value -Count $Entries.Count -AllowAll)
                return @($indices | ForEach-Object {
                    $Entries[$_ - 1]
                })
            }
            $selected = [Collections.Generic.List[object]]::new()
            $names = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($token in $value.Split(',')) {
                $item = $token.Trim()
                $number = 0
                if ([int]::TryParse($item, [ref]$number) -and
                    $number -ge 1 -and
                    $number -le $Entries.Count) {
                    $entry = $Entries[$number - 1]
                }
                else {
                    $entry = $Entries | Where-Object {
                        $_.Model.Name -ieq $item
                    } | Select-Object -First 1
                }
                if ($null -eq $entry) {
                    throw (Get-LocalizedText `
                        -Key 'Manager.Error.ModelNotFound' `
                        -Arguments @($item))
                }
                if ($names.Add($entry.Model.Name)) {
                    $selected.Add($entry)
                }
            }
            return $selected.ToArray()
        }
        catch {
            if (-not $interactive) {
                throw
            }
            Write-ManagerStatus -Level WARN `
                -Message $_.Exception.Message
            $value = ''
        }
    }
}
function Invoke-ComfyUIDownloadAction {
    $entries = @(Get-ComfyUICatalogEntries | Where-Object {
        $property = $_.Model.PSObject.Properties['InstallReady']
        $null -eq $property -or [bool]$property.Value
    })
    Show-ComfyUICatalog -Entries $entries
    if ($entries.Count -eq 0) {
        return
    }
    Write-ManagerLine -Text (Get-LocalizedText `
        -Key 'Manager.ComfyUI.RequiresComfyUI') -Color Yellow
    Write-ManagerRule
    $selected = @(Resolve-ComfyUISelection -Entries $entries)
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.ComfyUI.Cancelled'
        return
    }
    foreach ($item in $selected) {
        if (Test-ComfyUIModelInstalled `
            -Model $item.Model -VerifyHash) {
            Write-ManagerStatus -Level OK `
                -Message 'Manager.ComfyUI.AlreadyInstalled' `
                -MessageArguments @($item.Model.Name)
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($item.SourcePath)) {
            Write-ManagerStatus -Level INFO `
                -Message 'Manager.ComfyUI.LocalCopying' `
                -MessageArguments @($item.Model.Name)
            Copy-ComfyUILocalModel -Model $item.Model `
                -Source $item.SourcePath
            Write-ManagerStatus -Level OK `
                -Message 'Manager.ComfyUI.LocalCopyCompleted' `
                -MessageArguments @($item.Model.Name)
            continue
        }
        $localOnly = [bool](Get-JsonValue -InputObject $item.Model `
            -Name LocalOnly -DefaultValue $false)
        if ($localOnly) {
            Write-ManagerStatus -Level WARN `
                -Message 'Installer.ComfyUI.LocalOnlyMissing' `
                -MessageArguments @($item.Model.Name)
            continue
        }
        Assert-ComfyUIDownloadDiskSpace -Model $item.Model
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.ComfyUI.DownloadStarting' `
            -MessageArguments @($item.Model.Name)
        $null = Install-ComfyUIModelPayload -Model $item.Model
        if (-not (Test-ComfyUIModelInstalled `
            -Model $item.Model -VerifyHash)) {
            throw (Get-LocalizedText `
                -Key 'Manager.ComfyUI.VerificationFailed' `
                -Arguments @($item.Model.Name))
        }
        Write-ManagerStatus -Level OK `
            -Message 'Manager.ComfyUI.DownloadCompleted' `
            -MessageArguments @($item.Model.Name)
    }
    Write-ManagerStatus -Level OK `
        -Message 'Manager.ComfyUI.AllCompleted' `
        -MessageArguments @($selected.Count)
}
function Invoke-ComfyUIDeleteAction {
    $entries = @(Get-ComfyUICatalogEntries)
    Show-ComfyUICatalog -Entries $entries
    if ($entries.Count -eq 0) {
        return
    }
    $selected = @(Resolve-ComfyUISelection -Entries $entries -Delete)
    if ($selected.Count -eq 0) {
        Write-ManagerStatus -Level INFO `
            -Message 'Manager.ComfyUI.DeleteCancelled'
        return
    }
    if (-not $ConfirmDelete) {
        if ($Action -ne 'Menu') {
            throw (Get-LocalizedText `
                -Key 'Manager.Error.DeleteConfirmationRequired')
        }
        $confirmed = Confirm-ManagerAction -Prompt (Get-LocalizedText `
            -Key 'Manager.ComfyUI.DeleteConfirm') -NoLeadingRule
        if (-not $confirmed) {
            Write-ManagerStatus -Level INFO `
                -Message 'Manager.ComfyUI.DeleteCancelled'
            return
        }
    }
    $selectedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in $selected) {
        $null = $selectedNames.Add($item.Model.Name)
    }
    $protected = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $entries) {
        if ($selectedNames.Contains($entry.Model.Name) -or
            -not $entry.IsLocal) {
            continue
        }
        foreach ($asset in @(Get-ComfyUIModelAssets `
            -Model $entry.Model)) {
            $null = $protected.Add(
                (Get-ComfyUIModelAssetPath -Asset $asset)
            )
        }
    }
    $removed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in $selected) {
        $assets = @(Get-ComfyUIModelAssets -Model $item.Model)
        $directory = Join-Path (Get-ComfyUIModelsRoot) `
            (Get-ComfyUIModelDirectoryName -Model $item.Model)
        $marker = Join-Path $directory '.winlama-local-model'
        if ($assets.Count -eq 0 -or
            (Test-Path -LiteralPath $marker -PathType Leaf)) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Remove-Item -LiteralPath $directory -Recurse -Force
            }
            Write-ManagerStatus -Level OK `
                -Message 'Manager.ComfyUI.Deleted' `
                -MessageArguments @($item.Model.Name)
            continue
        }
        foreach ($asset in $assets) {
            $path = Get-ComfyUIModelAssetPath -Asset $asset
            if ($protected.Contains($path)) {
                continue
            }
            if ($removed.Add($path) -and
                (Test-Path -LiteralPath $path -PathType Leaf)) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        Write-ManagerStatus -Level OK `
            -Message 'Manager.ComfyUI.Deleted' `
            -MessageArguments @($item.Model.Name)
    }
}
function Invoke-ManagerAction {
    param(
        [ValidateSet(
            'List', 'Packages', 'Export',
            'Import', 'Verify', 'Delete', 'PackageDelete', 'Download',
            'ComfyUIList', 'ComfyUIDownload', 'ComfyUIDelete'
        )]
        [string]$SelectedAction
    )
    switch ($SelectedAction) {
        'List' { Invoke-ListAction }
        'Packages' { Invoke-PackageListAction }
        'Export' { Invoke-ExportAction }
        'Import' { Invoke-ImportAction }
        'Verify' { Invoke-VerifyAction }
        'Delete' { Invoke-DeleteAction }
        'PackageDelete' { Invoke-PackageDeleteAction }
        'Download' { Invoke-DownloadAction }
        'ComfyUIList' { Invoke-ComfyUIListAction }
        'ComfyUIDownload' { Invoke-ComfyUIDownloadAction }
        'ComfyUIDelete' { Invoke-ComfyUIDeleteAction }
    }
}
function Show-ManagerPaths {
    $models = Expand-ManagerPath -Path `
        $script:ManagerConfig.Paths.Models
    $exports = Expand-ManagerPath -Path `
        $script:ManagerConfig.ModelTransfer.ExportDirectory
    $comfyModels = Get-ComfyUIModelsRoot
    Write-ManagerKeyValueTableRow `
        -Label (Get-LocalizedText `
            -Key 'Manager.Path.ImportTargetLabel') -Value $models
    Write-ManagerKeyValueTableRow `
        -Label (Get-LocalizedText `
            -Key 'Manager.Path.PackagesLabel') -Value $exports
    Write-ManagerKeyValueTableRow `
        -Label (Get-LocalizedText `
            -Key 'Manager.Path.ComfyUIModelsLabel') -Value $comfyModels
    foreach ($path in @(Get-NativeModelSearchDirectories)) {
        Write-ManagerKeyValueTableRow `
            -Label (Get-LocalizedText `
                -Key 'Manager.Path.ModelSearchLabel') -Value $path
    }
    Write-ManagerRule
}
function Invoke-InteractiveManagerAction {
    param(
        [Parameter(Mandatory)][string]$SelectedAction,
        [scriptblock]$PauseReader
    )
    $failed = $false
    try {
        Invoke-ManagerAction -SelectedAction $SelectedAction
    }
    catch {
        $failed = $true
        Write-ManagerError -Context (Get-LocalizedText `
            -Key 'Manager.Operation.ActionFailedContext') `
            -ErrorRecord $_
        Write-ManagerLog -Level ERROR -Event ACTION_FAILED `
            -Message 'Manager.Log.ActionFailed' `
            -Data @{ Action = $SelectedAction;
                Error = $_.Exception.ToString() }
    }
    Complete-WinlamaUIOperation `
        -Summary $(if ($failed) {
            Get-LocalizedText -Key 'Manager.Operation.ActionFailed'
        }
        else {
            Get-LocalizedText -Key 'Manager.Operation.ActionCompleted'
        }) `
        -Level $(if ($failed) { 'ERROR' } else { 'SUCCESS' }) `
        -Command DEVAM -InputReader $PauseReader
}
function Get-ComputerModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.Computer.List'; Action = 'List';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.Computer.Download'; Action = 'Download';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.Computer.Import'; Action = 'Import';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '4';
            Key = 'Manager.Computer.Export'; Action = 'Export';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '5';
            Key = 'Manager.Computer.Delete'; Action = 'Delete';
            Color = 'Red' }
    )
}
function Get-InstallationModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.Installation.List'; Action = 'Packages';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.Installation.Verify'; Action = 'Verify';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.Installation.Import'; Action = 'Export';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '4';
            Key = 'Manager.Installation.Export'; Action = 'Import';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '5';
            Key = 'Manager.Installation.Delete';
            Action = 'PackageDelete'; Color = 'Red' }
    )
}
function Get-ComfyUIModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.ComfyUI.List'; Action = 'ComfyUIList';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.ComfyUI.Download'; Action = 'ComfyUIDownload';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.ComfyUI.Delete'; Action = 'ComfyUIDelete';
            Color = 'Red' }
    )
}
function Get-ManagerMainMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1'; Key = 'Manager.Menu.Computer';
            Color = 'Green'; Arguments = @() }
        [pscustomobject]@{ Choice = '2'; Key = 'Manager.Menu.Installation';
            Color = 'Cyan'; Arguments = @() }
        [pscustomobject]@{ Choice = '3'; Key = 'Manager.Menu.ComfyUIModels';
            Color = 'Magenta'; Arguments = @('3') }
        [pscustomobject]@{ Choice = '4'; Key = 'Manager.Menu.Repair';
            Color = 'Yellow'; Arguments = @() }
        [pscustomobject]@{ Choice = '5'; Key = 'Manager.Menu.Uninstall';
            Color = 'Red'; Arguments = @() }
        [pscustomobject]@{ Choice = '0'; Key = 'Manager.Menu.Exit';
            Color = 'Gray'; Arguments = @() }
    )
}
function Assert-ManagerMenuContract {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string[]]$ExpectedColors,
        [switch]$HasBack
    )
    $expected = @(1..$Items.Count | ForEach-Object { [string]$_ })
    if ($Items[-1].Choice -eq '0') {
        $expected = @(1..($Items.Count - 1) |
            ForEach-Object { [string]$_ }) + '0'
    }
    if (($Items.Choice -join ',') -ne ($expected -join ',')) {
        throw 'Model yoneticisi menu numaralari veya sirasi gecersiz.'
    }
    if (($Items.Color -join ',') -ne ($ExpectedColors -join ',')) {
        throw 'Model yoneticisi menu renk sirasi gecersiz.'
    }
    $texts = @()
    foreach ($item in $Items) {
        $arguments = if ($null -ne `
            $item.PSObject.Properties['Arguments']) {
            @($item.Arguments)
        }
        else {
            @()
        }
        $text = if (@($arguments).Count -gt 0) {
            Get-LocalizedText -Key $item.Key -Arguments $arguments
        }
        else {
            Get-LocalizedText -Key $item.Key
        }
        if ($text -notmatch ('^\s*\[{0}\]\s+\S' -f $item.Choice)) {
            throw "Model yoneticisi menu etiketi gecersiz: $($item.Key)"
        }
        $texts += $text.Trim()
    }
    if (@($texts | Sort-Object -Unique).Count -ne $Items.Count) {
        throw 'Model yoneticisi menusunde yinelenen etiket var.'
    }
    if ($HasBack) {
        $back = Get-LocalizedText -Key 'Manager.Menu.Back'
        if ($back -notmatch '^\s*\[0\]\s+\S') {
            throw 'Model yoneticisi geri etiketi gecersiz.'
        }
    }
}
function Show-ManagerActionMenuLayout {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Notice
    )
    Write-ManagerBanner
    Show-ManagerPaths
    Write-ManagerSection -Title $Title -NoLeadingRule
    if (-not [string]::IsNullOrWhiteSpace($Notice)) {
        Write-ManagerLine -Text (Get-LocalizedText -Key $Notice) `
            -Color Cyan
        Write-ManagerRule
    }
    foreach ($item in $Items) {
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key $item.Key) -Color $item.Color
    }
    Write-ManagerLine -Text (Get-LocalizedText `
        -Key 'Manager.Menu.Back') -Color Gray
    Write-ManagerRule
}
function Show-ManagerMainMenu {
    Write-ManagerBanner
    Show-ManagerPaths
    foreach ($item in @(Get-ManagerMainMenuItems)) {
        $text = if (@($item.Arguments).Count -gt 0) {
            Get-LocalizedText -Key $item.Key -Arguments $item.Arguments
        }
        else {
            Get-LocalizedText -Key $item.Key
        }
        Write-ManagerLine -Text $text -Color $item.Color
    }
    Write-ManagerRule
}
function Show-ManagerPromptValidation {
    $keys = @(
        'Manager.Prompt.Models',
        'Manager.Prompt.DeleteModels',
        'Manager.Prompt.Packages',
        'Manager.Prompt.DeletePackages',
        'Manager.Prompt.DeleteConfirm',
        'Manager.Prompt.PackageDeleteConfirm',
        'Manager.Prompt.DownloadModels',
        'Manager.Prompt.DownloadSource',
        'Manager.ComfyUI.SelectModels',
        'Manager.ComfyUI.SelectDeleteModels',
        'Manager.ComfyUI.DeleteConfirm',
        'Common.Prompt.Selection',
        'Common.Prompt.ReturnToMenu',
        'Common.Prompt.Close'
    )
    Write-ManagerSection -Title 'Manager.Section.ComputerModels'
    foreach ($key in $keys) {
        $text = Get-LocalizedText -Key $key
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq $key) {
            throw "Model yoneticisi istemi gecersiz: $key"
        }
        if ($key -ceq 'Common.Prompt.Selection') {
            $expected = 'Se{0}iminiz' -f [char]0x00E7
            if ($text.TrimEnd(':') -cne $expected) {
                throw "Model yoneticisi istemi gecersiz: $key"
            }
            $text = '{0}:' -f $text.TrimEnd(':')
        }
        elseif ($text -match '[^\x00-\x7F]') {
            throw "Model yoneticisi istemi gecersiz: $key"
        }
        Write-ManagerLine -Text $text -Color White
    }
    Write-ManagerRule
}
function Invoke-ManagerActionMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Notice,
        [scriptblock]$InputReader,
        [switch]$NoClear,
        [switch]$SkipDelay
    )
    while ($true) {
        if (-not $NoClear) {
            Clear-Host
        }
        Show-ManagerActionMenuLayout -Title $Title -Items $Items `
            -Notice $Notice
        $choice = Read-ManagerInput -Prompt (Get-LocalizedText `
            -Key 'Common.Prompt.Selection') `
            -InputReader $InputReader -NoLeadingRule
        if ($choice -eq '0') {
            return
        }
        $selected = $Items | Where-Object Choice -EQ $choice |
            Select-Object -First 1
        if ($null -eq $selected) {
            Write-ManagerStatus -Level WARN `
                -Message 'Common.Selection.Invalid'
            if (-not $SkipDelay) {
                Start-Sleep -Seconds 1
            }
            continue
        }
        Invoke-InteractiveManagerAction `
            -SelectedAction $selected.Action
    }
}
function Invoke-ComputerModelsMenu {
    $items = @(Get-ComputerModelsMenuItems)
    Invoke-ManagerActionMenu -Title 'Manager.Section.ComputerModels' `
        -Items $items
}
function Invoke-InstallationModelsMenu {
    $items = @(Get-InstallationModelsMenuItems)
    Invoke-ManagerActionMenu `
        -Title 'Manager.Section.InstallationModels' -Items $items `
        -Notice 'Manager.Installation.VerifyNotice'
}
function Invoke-ComfyUIModelsMenu {
    $items = @(Get-ComfyUIModelsMenuItems)
    Invoke-ManagerActionMenu -Title 'Manager.Section.ComfyUIModels' `
        -Items $items
}
function Test-ManagerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
function Invoke-UninstallManager {
    Write-ManagerStatus -Level WARN `
        -Message 'Manager.Uninstall.ReturnToLauncher'
    return $false
}
function Get-ManagerRepairOutcome {
    param([Parameter(Mandatory)][int]$ExitCode)
    switch ($ExitCode) {
        0 { return 'Success' }
        2 { return 'Cancelled' }
        3 { return 'Incomplete' }
        default { return 'Failed' }
    }
}
function Invoke-RepairManager {
    if (-not (Test-ManagerAdministrator)) {
        Write-ManagerStatus -Level WARN `
            -Message 'Manager.Repair.ReturnToLauncher'
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Manager.Operation.RepairAdminRequired') `
                -Level WARN -Command DEVAM
        }
        return $false
    }
    $path = Join-Path $PSScriptRoot 'Repair.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Manager.Error.RepairMissing')
    }
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile `
        -ExecutionPolicy Bypass -File $path -NoPause
    $repairExitCode = [int]$LASTEXITCODE
    $repairOutcome = Get-ManagerRepairOutcome `
        -ExitCode $repairExitCode
    if ($repairOutcome -ceq 'Cancelled') {
        Write-ManagerStatus -Level SKIP `
            -Message 'Launcher.Operation.ScriptCancelled' `
            -MessageArguments @('Repair.ps1')
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Launcher.Operation.ScriptCancelled' `
                    -Arguments @('Repair.ps1')) `
                -Level SKIP -Command DEVAM
        }
        return $true
    }
    if ($repairOutcome -ceq 'Incomplete') {
        Write-ManagerStatus -Level WARN `
            -Message 'Launcher.Operation.ScriptIncomplete' `
            -MessageArguments @('Repair.ps1')
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-LocalizedText `
                    -Key 'Launcher.Operation.ScriptIncomplete' `
                    -Arguments @('Repair.ps1')) `
                -Level WARN -Command DEVAM
        }
        return $true
    }
    if ($repairOutcome -ceq 'Failed') {
        throw (Get-LocalizedText -Key 'Manager.Error.RepairFailed' `
            -Arguments @($repairExitCode))
    }
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Manager.Operation.RepairCompleted') `
            -Level SUCCESS -Command DEVAM
    }
    return $true
}
function Invoke-ManagerMenu {
    param(
        [scriptblock]$InputReader,
        [switch]$NoClear,
        [switch]$SkipDelay
    )
    while ($true) {
        if (-not $NoClear) {
            Clear-Host
        }
        Show-ManagerMainMenu
        $choice = Read-ManagerInput -Prompt (Get-LocalizedText `
            -Key 'Common.Prompt.Selection') `
            -InputReader $InputReader -NoLeadingRule
        switch ($choice) {
            '0' { return }
            '1' { Invoke-ComputerModelsMenu }
            '2' { Invoke-InstallationModelsMenu }
            '3' { Invoke-ComfyUIModelsMenu }
            '4' {
                if (-not (Invoke-RepairManager)) {
                    return
                }
            }
            '5' {
                if (-not (Invoke-UninstallManager)) {
                    return
                }
            }
            default {
                Write-ManagerStatus -Level WARN `
                    -Message 'Common.Selection.Invalid'
                if (-not $SkipDelay) {
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
}
$exitCode = 0
try {
    Write-Verbose (Get-LocalizedText `
        -Key 'Verbose.Validation.Started' `
        -Arguments @('ModelManager.ps1'))
    Initialize-Manager
    if ($ValidateOnly) {
        $null = Assert-WinlamaUIStandard
        $null = Assert-ManagerBootstrapInputContracts
        $null = Assert-ManagerKeyValueTableContracts
        $null = Assert-ManagerOllamaApplicationContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-ManagerBootstrapInputLine -Value $Value
        }
        $mainItems = @(Get-ManagerMainMenuItems)
        $computerItems = @(Get-ComputerModelsMenuItems)
        $installationItems = @(Get-InstallationModelsMenuItems)
        $comfyItems = @(Get-ComfyUIModelsMenuItems)
        Assert-ManagerMenuContract -Items $mainItems `
            -ExpectedColors @(
                'Green', 'Cyan', 'Magenta', 'Yellow',
                'Red', 'Gray'
            )
        Assert-ManagerMenuContract -Items $computerItems `
            -ExpectedColors @(
                'White', 'Green', 'Cyan', 'Magenta', 'Red'
            ) -HasBack
        Assert-ManagerMenuContract -Items $installationItems `
            -ExpectedColors @(
                'White', 'Green', 'Magenta', 'Cyan', 'Red'
            ) -HasBack
        Assert-ManagerMenuContract -Items $comfyItems `
            -ExpectedColors @('White', 'Green', 'Red') -HasBack
        Show-ManagerMainMenu
        Write-Verbose 'WINLAMA_UI_OK:ModelManager.Main'
        Show-ManagerActionMenuLayout `
            -Title 'Manager.Section.ComputerModels' `
            -Items $computerItems
        Write-Verbose 'WINLAMA_UI_OK:ModelManager.Computer'
        Show-ManagerActionMenuLayout `
            -Title 'Manager.Section.InstallationModels' `
            -Items $installationItems `
            -Notice 'Manager.Installation.VerifyNotice'
        Write-Verbose 'WINLAMA_UI_OK:ModelManager.Packages'
        Show-ManagerActionMenuLayout `
            -Title 'Manager.Section.ComfyUIModels' -Items $comfyItems
        Write-Verbose 'WINLAMA_UI_OK:ModelManager.ComfyUI'
        Show-ManagerPromptValidation
        Write-Verbose 'WINLAMA_UI_OK:ModelManager.Prompts'
        $mainSelections = [Collections.Generic.Queue[string]]::new()
        $mainSelections.Enqueue('')
        $mainSelections.Enqueue('X')
        $mainSelections.Enqueue('0')
        $mainReader = {
            param([string]$Label)
            return $mainSelections.Dequeue()
        }.GetNewClosure()
        Invoke-ManagerMenu -InputReader $mainReader `
            -NoClear -SkipDelay
        $subSelections = [Collections.Generic.Queue[string]]::new()
        $subSelections.Enqueue('')
        $subSelections.Enqueue('X')
        $subSelections.Enqueue('0')
        $subReader = {
            param([string]$Label)
            return $subSelections.Dequeue()
        }.GetNewClosure()
        Invoke-ManagerActionMenu `
            -Title 'Manager.Section.ComputerModels' `
            -Items $computerItems -InputReader $subReader `
            -NoClear -SkipDelay
        $accepted = Confirm-ManagerAction -Prompt (
            Get-LocalizedText -Key 'Manager.Prompt.DeleteConfirm'
        ) -InputReader { param([string]$Label) return 'EVET' } `
            -NoLeadingRule
        $rejected = Confirm-ManagerAction -Prompt (
            Get-LocalizedText -Key 'Manager.Prompt.DeleteConfirm'
        ) -InputReader { param([string]$Label) return 'HAYIR' } `
            -NoLeadingRule
        if (-not $accepted -or $rejected) {
            throw 'Model yoneticisi onay istemi gecersiz.'
        }
        if ((Resolve-ManagerDownloadSourceSelection -Value 'YEREL') `
                -cne 'Local' -or
            (Resolve-ManagerDownloadSourceSelection -Value 'INTERNET') `
                -cne 'Internet' -or
            (Resolve-ManagerDownloadSourceSelection -Value '0') `
                -cne 'Cancel' -or
            $null -ne (Resolve-ManagerDownloadSourceSelection -Value '') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection -Value 'Y') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection -Value 'I') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection `
                -Value 'yerel') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection `
                -Value ' YEREL ') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection `
                -Value 'internet') -or
            $null -ne (Resolve-ManagerDownloadSourceSelection `
                -Value ' INTERNET ')) {
            throw 'Model yoneticisi kesin kaynak secimi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_UI_INPUT_OK:ModelManager.ExactDownloadSource'
        $errorStyle = Get-WinlamaUIStatusStyle -Level ERROR
        if ($errorStyle.Label -cne 'HATA' -or
            $errorStyle.Color -cne 'Red') {
            throw 'Model yoneticisi hata arayuzu renk sozlesmesi gecersiz.'
        }
        $repairOutcomes = @(0, 2, 3, 1, 10 | ForEach-Object {
            Get-ManagerRepairOutcome -ExitCode $_
        })
        if (($repairOutcomes -join '|') -cne
            'Success|Cancelled|Incomplete|Failed|Failed') {
            throw 'Model yoneticisi onarim cikis sozlesmesi gecersiz.'
        }
        Write-Verbose `
            'WINLAMA_VALIDATION_OK:ModelManager.RepairExitContract'
        $validationLogPath = $script:LogPath
        try {
            $script:LogPath = $PSScriptRoot
            Write-ManagerLog -Level ERROR -Event VALIDATION `
                -Message 'Manager.Log.Stopped' -Data $null
        }
        finally {
            $script:LogPath = $validationLogPath
        }
        Write-Verbose 'WINLAMA_VALIDATION_OK:ModelManager.LogFailureSafe'
        Write-Verbose 'WINLAMA_UI_INPUT_OK:ModelManager.Validation'
        Write-Verbose 'WINLAMA_UI_CONFIRM_OK:ModelManager.Validation'
        Write-Verbose 'WINLAMA_UI_ERROR_OK:ModelManager.Validation'
        Write-Verbose (Get-LocalizedText `
            -Key 'Verbose.Validation.Completed' `
            -Arguments @('ModelManager.ps1'))
        Write-Verbose 'WINLAMA_VALIDATION_OK:ModelManager.ps1'
        exit 0
    }
    if (-not (Set-WinlamaProcessPriority `
        -Priority $script:ManagerConfig.Runtime.ProcessPriority)) {
        Write-ManagerStatus -Level WARN `
            -Message 'Common.Priority.Failed'
    }
    if ($Action -eq 'Menu') {
        Invoke-ManagerMenu
    }
    else {
        Write-ManagerBanner
        Show-ManagerPaths
        Invoke-ManagerAction -SelectedAction $Action
    }
    Write-ManagerLog -Level INFO -Event STOP `
        -Message 'Manager.Log.Stopped' -Data $null
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Manager.Operation.Completed') `
            -Level SUCCESS -Command CIKIS
    }
}
catch {
    $exitCode = 1
    Write-ManagerError -Context (Get-LocalizedText `
        -Key 'Manager.Operation.FailedContext') `
        -ErrorRecord $_
    Write-Verbose ('Hata konumu: satir {0}, sutun {1}' -f `
        $_.InvocationInfo.ScriptLineNumber,
        $_.InvocationInfo.OffsetInLine)
    Write-Verbose ('Hata turu: {0}' -f `
        $_.Exception.GetType().FullName)
    Write-ManagerLog -Level ERROR -Event FATAL `
        -Message 'Manager.Log.Fatal' `
        -Data @{ Error = $_.Exception.ToString() }
    if (-not $NoPause) {
        Complete-WinlamaUIOperation `
            -Summary (Get-LocalizedText `
                -Key 'Manager.Operation.Failed') `
            -Level ERROR -Command CIKIS
    }
}
exit $exitCode