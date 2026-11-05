#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [string]$ConfigPath,
    [ValidateSet(
        'Menu', 'PackageToInstalled', 'PublishPackage', 'RepairAll'
    )]
    [string]$Mode = 'Menu',
    [switch]$Apply,
    [switch]$Preview,
    [switch]$SkipInstaller,
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [switch]$GenerateReport,
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
        'Repair oturum kimligi gecersiz.'
    )
}
function ConvertFrom-RepairJson {
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
function Write-RepairBootstrapRule {
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
function Write-RepairBootstrapLine {
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
function Get-RepairBootstrapStatusStyle {
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
function Get-RepairBootstrapStatusWidth {
    $width = 0
    foreach ($level in @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    )) {
        $style = Get-RepairBootstrapStatusStyle -Level $level
        $width = [Math]::Max($width, $style.Label.Length)
    }
    return $width
}
function Write-RepairBootstrapSegment {
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
function Write-RepairBootstrapStatus {
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
    $style = Get-RepairBootstrapStatusStyle -Level $Level
    $width = Get-RepairBootstrapStatusWidth
    $left = [Math]::Floor(($width - $style.Label.Length) / 2)
    $label = ((' ' * $left) + $style.Label).PadRight($width)
    $messageWidth = 96 - $width - 3
    foreach ($logicalLine in [regex]::Split($Message, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        $lineLabel = $label
        do {
            $length = [Math]::Min($messageWidth, $remaining.Length)
            $part = $remaining.Substring(0, $length)
            Write-RepairBootstrapSegment -Text '| ' -Color Gray `
                -NoNewline
            Write-RepairBootstrapSegment -Text $lineLabel `
                -Color $style.Color -NoNewline
            Write-RepairBootstrapSegment -Text ' | ' -Color Gray `
                -NoNewline
            Write-RepairBootstrapSegment `
                -Text $part.PadRight($messageWidth) -Color White `
                -NoNewline
            Write-RepairBootstrapSegment -Text ' |' -Color Gray
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
function Format-RepairBootstrapInputLine {
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
function ConvertFrom-RepairBootstrapReadValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        throw [IO.EndOfStreamException]::new(
            'Standart girdi kapali; zorunlu komut okunamadi.'
        )
    }
    return [string]$Value
}
function Test-RepairBootstrapExactExit {
    param([AllowNull()][string]$Value)
    return $null -ne $Value -and $Value -ceq 'CIKIS'
}
function Assert-RepairBootstrapInputContracts {
    $eofRejected = $false
    try {
        $null = ConvertFrom-RepairBootstrapReadValue -Value $null
    }
    catch [IO.EndOfStreamException] {
        $eofRejected = $true
    }
    if (-not $eofRejected -or
        (ConvertFrom-RepairBootstrapReadValue -Value '') -cne '') {
        throw 'Onarim bootstrap EOF girdi sozlesmesi gecersiz.'
    }
    foreach ($invalid in @('', 'C', 'cikis', 'Cikis', ' CIKIS ')) {
        if (Test-RepairBootstrapExactExit -Value $invalid) {
            throw 'Onarim bootstrap kesin CIKIS sozlesmesi gecersiz.'
        }
    }
    if (-not (Test-RepairBootstrapExactExit -Value 'CIKIS')) {
        throw 'Onarim bootstrap kesin CIKIS sozlesmesi gecersiz.'
    }
    $statusSource = (Get-Command Write-RepairBootstrapStatus `
        -ErrorAction Stop).Definition
    if (-not $statusSource.Contains('-Text $lineLabel') -or
        -not $statusSource.Contains('-Color $style.Color') -or
        -not $statusSource.Contains(
            '-Text $part.PadRight($messageWidth) -Color White'
        )) {
        throw 'Onarim bootstrap renk segmenti sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:Repair.BootstrapEOF'
    Write-Verbose 'WINLAMA_UI_OK:Repair.BootstrapExactExit'
    Write-Verbose 'WINLAMA_UI_OK:Repair.BootstrapSegmentedColor'
    return $true
}
function Read-RepairBootstrapRawInput {
    if ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-RepairBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-RepairBootstrapInputLine -Value $value))
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
                (Format-RepairBootstrapInputLine -Value $value))
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
            (Format-RepairBootstrapInputLine -Value $value))
        return $value
    }
    catch {
        $readValue = $Host.UI.ReadLine()
        $value = ConvertFrom-RepairBootstrapReadValue `
            -Value $readValue
        $Host.UI.WriteLine([ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-RepairBootstrapInputLine -Value $value))
        return $value
    }
}
function Write-RepairBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $command = Get-Command Write-WinlamaUIError `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Context = Get-WinlamaUIString `
            -Key 'Repair.Operation.UnexpectedFailure' `
            -Fallback $Context
        & $command -Context $Context -ErrorRecord $ErrorRecord
        return
    }
    Write-RepairBootstrapRule -Character '='
    Write-RepairBootstrapLine -Text 'ISLEM OZETI' -Color Cyan
    Write-RepairBootstrapStatus -Level ERROR -Message $Context
    Write-RepairBootstrapStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-RepairBootstrapStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-RepairBootstrapRule -Character '='
}
function Read-RepairBootstrapInput {
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
    Write-RepairBootstrapRule
    Write-RepairBootstrapStatus -Level INFO -Message $Prompt
    Write-RepairBootstrapStatus -Level DETAIL `
        -Message 'Yalniz tam olarak CIKIS yazin.'
    Write-RepairBootstrapRule
    $value = Read-RepairBootstrapRawInput
    Write-RepairBootstrapRule
    return $value
}
trap {
    Write-RepairBootstrapError `
        -Context 'Onarim beklenmeyen bir hatayla durdu.' `
        -ErrorRecord $_
    if (-not $ValidateOnly -and -not $NoPause) {
        do {
            $answer = Read-RepairBootstrapInput `
                -Prompt 'Onarim oturumunu kapatmak icin CIKIS yazin.'
            if (-not (Test-RepairBootstrapExactExit -Value $answer)) {
                Write-RepairBootstrapStatus -Level WARN `
                    -Message 'Bos veya gecersiz komut kabul edilmedi.'
            }
        } while (-not (Test-RepairBootstrapExactExit -Value $answer))
    }
    exit 1
}
Import-Module (Join-Path $PSScriptRoot `
    'Modules\UI\ConsoleUI.psm1') -Force -ErrorAction Stop
try {
    $host.UI.RawUI.WindowTitle = Get-WinlamaUIString `
        -Key 'Repair.WindowTitle' `
        -Fallback 'Winlama - Onarim merkezi'
}
catch {
    Write-Verbose ('Pencere basligi ayarlanamadi: {0}' -f `
        $_.Exception.Message)
}
$script:CopiedCount = 0
$script:DeletedCount = 0
$script:MatchedCount = 0
$script:DifferentCount = 0
$script:ResolvedCount = 0
$script:RemainingCount = $null
$script:FailedItems = [Collections.Generic.List[string]]::new()
$script:UnresolvedItems = [Collections.Generic.List[string]]::new()
$script:SkippedItems = [Collections.Generic.List[string]]::new()
$script:RepairConfigurationEvents = `
    [Collections.Generic.List[string]]::new()
$script:RepairLogPath = $null
$script:RepairReportPath = $null
$script:RepairReportsDirectory = $null
$script:RepairLogWriteFailureCount = 0
$script:RepairMode = $null
$script:RepairSource = $null
$script:RepairTarget = $null
$script:RepairStartedAt = [DateTimeOffset]::Now
$script:RepairFallbackText = @{
    'Repair.Error.Failed' = 'Onarim tamamlanamadi: {0}'
    'Repair.Report.Failed' = 'Onarim raporu olusturulamadi: {0}'
    'Repair.Report.Created' = 'Onarim raporu olusturuldu: {0}'
}
function Resolve-RepairPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BasePath = $PSScriptRoot
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $BasePath $expanded
    }
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}
function Resolve-RepairConfigPath {
    param([string]$Path, [string]$Root = $PSScriptRoot)
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
        (Join-Path $Root 'Data\Configs\config.json')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "Winlama yapilandirma dosyasi bulunamadi: $Root"
}
function Initialize-RepairLocalization {
    param([Parameter(Mandatory)][string]$Path)
    $module = Join-Path $PSScriptRoot `
        'Modules\Localization\LocalizationManager.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        return
    }
    $configuration = Get-Content -LiteralPath $Path -Raw `
        -Encoding UTF8 | ConvertFrom-RepairJson
    Import-Module $module -Force -ErrorAction Stop
    $null = Initialize-Localization -ProjectRoot $PSScriptRoot `
        -Configuration $configuration.Localization
    try {
        $host.UI.RawUI.WindowTitle = Get-LocalizedText `
            -Key 'Repair.WindowTitle'
    }
    catch {
        Write-Verbose (Get-LocalizedText `
            -Key 'Common.Verbose.WindowTitleUnavailable' `
            -Arguments @($_.Exception.Message))
    }
}
function Get-RepairText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments = @()
    )
    $value = $Key
    if ($null -ne (Get-Command Get-LocalizedText `
        -ErrorAction SilentlyContinue)) {
        $value = Get-LocalizedText -Key $Key `
            -Arguments $Arguments
    }
    if ($value -ne $Key -or
        -not $script:RepairFallbackText.ContainsKey($Key)) {
        return $value
    }
    return $script:RepairFallbackText[$Key] -f $Arguments
}
function Initialize-RepairCommon {
    $module = Join-Path $PSScriptRoot 'Modules\00_Common.psm1'
    Import-Module $module -Force -ErrorAction Stop
}
function New-RepairTimestampedFile {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Extension,
        [string]$Prefix = ''
    )
    if ($null -ne (Get-Command New-WinlamaTimestampedFile `
        -ErrorAction SilentlyContinue)) {
        return New-WinlamaTimestampedFile `
            -Directory $Directory -Extension $Extension `
            -Prefix $Prefix
    }
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $name = [DateTimeOffset]::Now.ToString('yyyy-MM-dd_HH-mm-ss')
    $path = Join-Path $Directory "$Prefix$name$Extension"
    $suffix = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Directory `
            ("{0}{1}_{2}{3}" -f `
                $Prefix, $name, $suffix, $Extension)
        $suffix++
    }
    [IO.File]::WriteAllText(
        $path,
        '',
        [Text.UTF8Encoding]::new($false)
    )
    return $path
}
function Initialize-RepairDiagnostics {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$LogsPath = 'Logs',
        [string]$ReportsPath = 'Reports'
    )
    $logs = Resolve-RepairPath -Path $LogsPath -BasePath $Root
    $reports = Resolve-RepairPath -Path $ReportsPath -BasePath $Root
    if ([string]::IsNullOrWhiteSpace($script:RepairLogPath)) {
        $script:RepairLogPath = New-RepairTimestampedFile `
            -Directory $logs -Extension '.log'
    }
    $script:RepairReportsDirectory = $reports
}
function Initialize-RepairFallbackDiagnostics {
    $temporaryRoot = [IO.Path]::GetFullPath(
        [IO.Path]::GetTempPath()
    )
    if ([string]::IsNullOrWhiteSpace($script:RepairLogPath)) {
        $script:RepairLogPath = New-RepairTimestampedFile `
            -Directory (Join-Path $temporaryRoot 'Winlama-Logs') `
            -Extension '.log'
    }
    $script:RepairReportsDirectory = Join-Path $temporaryRoot `
        'Winlama-Reports'
}
function Get-RepairErrorData {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    return @{
        Exception = $ErrorRecord.Exception.ToString()
        Category = [string]$ErrorRecord.CategoryInfo
        FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        Position = $ErrorRecord.InvocationInfo.PositionMessage
        ScriptStackTrace = $ErrorRecord.ScriptStackTrace
    }
}
function Write-RepairLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [hashtable]$Data = @{},
        [scriptblock]$Writer
    )
    if ([string]::IsNullOrWhiteSpace($script:RepairLogPath)) {
        return
    }
    $displayLevel = switch ($Level) {
        'DEBUG' { Get-RepairText -Key 'Common.Level.Debug' }
        'ERROR' { Get-RepairText -Key 'Common.Level.Error' }
        'WARN' { Get-RepairText -Key 'Common.Level.Warning' }
        default { Get-RepairText -Key 'Common.Level.Info' }
    }
    $entry = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        level = $Level
        displayLevel = $displayLevel
        moduleCode = 'REPAIR'
        eventCode = $Event
        script = 'Repair.ps1'
        message = $Message
        processId = $PID
        sessionId = $SessionId
        data = $Data
    } | ConvertTo-Json -Depth 20 -Compress
    try {
        if ($null -eq $Writer) {
            Add-WinlamaUtf8Line `
                -Path $script:RepairLogPath -Value $entry
        }
        else {
            $null = & $Writer $script:RepairLogPath $entry
        }
    }
    catch {
        $script:RepairLogWriteFailureCount++
        $detail = $_.Exception.Message -replace '[\r\n]+', ' '
        if ($detail.Length -gt 240) {
            $detail = $detail.Substring(0, 240)
        }
        $warning = 'Onarim gunlugu yazilamadi: {0}' -f $detail
        Write-Verbose $warning
        try {
            Write-RepairStatus -Level WARN -Message $warning
        }
        catch {
            Write-Verbose ('Onarim gunluk uyarisi gosterilemedi: {0}' `
                -f $_.Exception.Message)
        }
    }
}
function Add-RepairFailure {
    param([Parameter(Mandatory)][string]$Message)
    $script:FailedItems.Add($Message)
    Write-RepairLog -Event 'ITEM_FAILED' -Message $Message `
        -Level ERROR
}
function Add-RepairUnresolved {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $script:UnresolvedItems.Contains($Message)) {
        $script:UnresolvedItems.Add($Message)
    }
    Write-RepairLog -Event 'ITEM_UNRESOLVED' -Message $Message `
        -Level WARN
}
function Add-RepairSkipped {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $script:SkippedItems.Contains($Message)) {
        $script:SkippedItems.Add($Message)
    }
    Write-RepairLog -Event 'ITEM_SKIPPED' -Message $Message `
        -Level WARN
}
function Get-RepairOutcome {
    $remaining = if ($null -eq $script:RemainingCount) {
        [Math]::Max(
            0,
            $script:DifferentCount - $script:ResolvedCount
        )
    }
    else {
        [int]$script:RemainingCount
    }
    $name = if ($script:FailedItems.Count -gt 0) {
        'Failed'
    }
    elseif ($remaining -gt 0 -or $script:SkippedItems.Count -gt 0) {
        'Incomplete'
    }
    else {
        'Success'
    }
    return [pscustomobject]@{
        Name = $name
        Remaining = $remaining
    }
}
function Get-RepairExitCode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Incomplete', 'Failed')]
        [string]$Outcome
    )
    switch ($Outcome) {
        'Success' { 0 }
        'Incomplete' { 3 }
        default { 1 }
    }
}
function ConvertTo-RepairHtmlList {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [string[]]$Items,
        [Parameter(Mandatory)][string]$EmptyText
    )
    $encoder = [Net.WebUtility]
    if ($Items.Count -eq 0) {
        return '<li>{0}</li>' -f $encoder::HtmlEncode($EmptyText)
    }
    return @($Items | ForEach-Object {
        '<li>{0}</li>' -f $encoder::HtmlEncode($_)
    }) -join ''
}
function Invoke-RepairNoThrowNotification {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Context
    )
    try {
        & $Action
        return $true
    }
    catch {
        Write-Verbose ('{0}: {1}' -f $Context, $_.Exception.Message)
        return $false
    }
}
function Write-RepairReport {
    if ([string]::IsNullOrWhiteSpace(
        $script:RepairReportsDirectory
    )) {
        return
    }
    $encoder = [Net.WebUtility]
    $outcome = Get-RepairOutcome
    $outcomeLabel = Get-RepairText `
        -Key "Repair.Report.Outcome.$($outcome.Name)"
    $modeLabel = Get-RepairText `
        -Key "Repair.Report.Mode.$($script:RepairMode)"
    $unresolvedItems = [Collections.Generic.List[string]]::new()
    foreach ($item in $script:UnresolvedItems) {
        $unresolvedItems.Add($item)
    }
    if ($outcome.Remaining -gt $unresolvedItems.Count) {
        $unresolvedItems.Add((Get-RepairText `
            -Key 'Repair.Unresolved.Count' `
            -Arguments @($outcome.Remaining)))
    }
    $failures = ConvertTo-RepairHtmlList `
        -Items $script:FailedItems.ToArray() `
        -EmptyText (Get-RepairText `
            -Key 'Repair.Report.Empty.Failures')
    $unresolved = ConvertTo-RepairHtmlList `
        -Items $unresolvedItems.ToArray() `
        -EmptyText (Get-RepairText `
            -Key 'Repair.Report.Empty.Unresolved')
    $skipped = ConvertTo-RepairHtmlList `
        -Items $script:SkippedItems.ToArray() `
        -EmptyText (Get-RepairText `
            -Key 'Repair.Report.Empty.Skipped')
    $configurationEvents = ConvertTo-RepairHtmlList `
        -Items $script:RepairConfigurationEvents.ToArray() `
        -EmptyText (Get-RepairText `
            -Key 'Repair.Report.Empty.ConfigRepairs')
    $html = @'
<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{{PAGE_TITLE}}</title><style>body{font-family:Segoe UI,sans-serif;max-width:980px;margin:32px auto;padding:0 20px;background:#111;color:#eee}h1{color:#56d6ff}table{border-collapse:collapse;width:100%;background:#1b1b1b}th,td{padding:10px;border:1px solid #444;text-align:left}th{color:#8eea9d}code{overflow-wrap:anywhere}li{margin:8px 0}.success{color:#8eea9d}.incomplete{color:#ffd166}.failed{color:#ff6b6b}</style></head><body><h1>{{PAGE_TITLE}}</h1><table><tr><th>{{START_LABEL}}</th><td>{{START}}</td></tr><tr><th>{{END_LABEL}}</th><td>{{END}}</td></tr><tr><th>{{OUTCOME_LABEL}}</th><td class="{{OUTCOME_CLASS}}">{{OUTCOME}}</td></tr><tr><th>{{MODE_LABEL}}</th><td>{{MODE}}</td></tr><tr><th>{{SOURCE_LABEL}}</th><td><code>{{SOURCE}}</code></td></tr><tr><th>{{TARGET_LABEL}}</th><td><code>{{TARGET}}</code></td></tr><tr><th>{{MATCHED_LABEL}}</th><td>{{MATCHED}}</td></tr><tr><th>{{DETECTED_LABEL}}</th><td>{{DETECTED}}</td></tr><tr><th>{{RESOLVED_LABEL}}</th><td>{{RESOLVED}}</td></tr><tr><th>{{REMAINING_LABEL}}</th><td>{{REMAINING}}</td></tr><tr><th>{{COPIED_LABEL}}</th><td>{{COPIED}}</td></tr><tr><th>{{DELETED_LABEL}}</th><td>{{DELETED}}</td></tr><tr><th>{{SKIPPED_LABEL}}</th><td>{{SKIPPED_COUNT}}</td></tr><tr><th>{{FAILED_LABEL}}</th><td>{{FAILED_COUNT}}</td></tr><tr><th>{{LOG_LABEL}}</th><td><code>{{LOG}}</code></td></tr></table><h2>{{CONFIG_REPAIRS_TITLE}}</h2><ul>{{CONFIG_REPAIRS}}</ul><h2>{{UNRESOLVED_TITLE}}</h2><ul>{{UNRESOLVED}}</ul><h2>{{SKIPPED_TITLE}}</h2><ul>{{SKIPPED}}</ul><h2>{{FAILURES_TITLE}}</h2><ul>{{FAILURES}}</ul></body></html>
'@
    $tokens = [ordered]@{
        '{{PAGE_TITLE}}' = Get-RepairText -Key 'Repair.Report.PageTitle'
        '{{START_LABEL}}' = Get-RepairText -Key 'Repair.Report.Start'
        '{{START}}' = $script:RepairStartedAt.ToString('o')
        '{{END_LABEL}}' = Get-RepairText -Key 'Repair.Report.End'
        '{{END}}' = [DateTimeOffset]::Now.ToString('o')
        '{{OUTCOME_LABEL}}' = Get-RepairText -Key 'Repair.Report.Outcome'
        '{{OUTCOME}}' = $outcomeLabel
        '{{OUTCOME_CLASS}}' = $outcome.Name.ToLowerInvariant()
        '{{MODE_LABEL}}' = Get-RepairText -Key 'Repair.Report.Mode'
        '{{MODE}}' = $modeLabel
        '{{SOURCE_LABEL}}' = Get-RepairText -Key 'Repair.Report.Source'
        '{{SOURCE}}' = [string]$script:RepairSource
        '{{TARGET_LABEL}}' = Get-RepairText -Key 'Repair.Report.Target'
        '{{TARGET}}' = [string]$script:RepairTarget
        '{{MATCHED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Matched'
        '{{MATCHED}}' = [string]$script:MatchedCount
        '{{DETECTED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Detected'
        '{{DETECTED}}' = [string]$script:DifferentCount
        '{{RESOLVED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Resolved'
        '{{RESOLVED}}' = [string]$script:ResolvedCount
        '{{REMAINING_LABEL}}' = Get-RepairText -Key 'Repair.Report.Remaining'
        '{{REMAINING}}' = [string]$outcome.Remaining
        '{{COPIED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Copied'
        '{{COPIED}}' = [string]$script:CopiedCount
        '{{DELETED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Deleted'
        '{{DELETED}}' = [string]$script:DeletedCount
        '{{SKIPPED_LABEL}}' = Get-RepairText -Key 'Repair.Report.Skipped'
        '{{SKIPPED_COUNT}}' = [string]$script:SkippedItems.Count
        '{{FAILED_LABEL}}' = Get-RepairText `
            -Key 'Repair.Report.FailedLabel'
        '{{FAILED_COUNT}}' = [string]$script:FailedItems.Count
        '{{LOG_LABEL}}' = Get-RepairText -Key 'Repair.Report.Log'
        '{{LOG}}' = [string]$script:RepairLogPath
        '{{CONFIG_REPAIRS_TITLE}}' = Get-RepairText `
            -Key 'Repair.Report.ConfigRepairsTitle'
        '{{CONFIG_REPAIRS}}' = $configurationEvents
        '{{UNRESOLVED_TITLE}}' = Get-RepairText `
            -Key 'Repair.Report.UnresolvedTitle'
        '{{UNRESOLVED}}' = $unresolved
        '{{SKIPPED_TITLE}}' = Get-RepairText `
            -Key 'Repair.Report.SkippedTitle'
        '{{SKIPPED}}' = $skipped
        '{{FAILURES_TITLE}}' = Get-RepairText `
            -Key 'Repair.Report.FailuresTitle'
        '{{FAILURES}}' = $failures
    }
    foreach ($token in $tokens.Keys) {
        $value = if ($token -in @(
            '{{CONFIG_REPAIRS}}', '{{UNRESOLVED}}',
            '{{SKIPPED}}', '{{FAILURES}}'
        )) {
            [string]$tokens[$token]
        }
        else {
            $encoder::HtmlEncode([string]$tokens[$token])
        }
        $html = $html.Replace($token, $value)
    }
    if ($html -match '\{\{[A-Z_]+\}\}') {
        throw 'Onarim raporunda doldurulmamis yer tutucu kaldi.'
    }
    $script:RepairReportPath = New-RepairTimestampedFile `
        -Directory $script:RepairReportsDirectory `
        -Extension '.html' -Prefix 'report-'
    $temporary = '{0}.winlama-{1}.tmp' -f `
        $script:RepairReportPath, [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            $html,
            [Text.UTF8Encoding]::new($false)
        )
        Set-RepairAtomicFile -TemporaryPath $temporary `
            -Destination $script:RepairReportPath
        $null = Invoke-RepairNoThrowNotification `
            -Context 'REPORT_CREATED log bildirimi' -Action {
                Write-RepairLog -Event 'REPORT_CREATED' `
                    -Message (Get-RepairText `
                        -Key 'Repair.Log.ReportCreated') `
                    -Data @{ Path = $script:RepairReportPath }
            }
        $null = Invoke-RepairNoThrowNotification `
            -Context 'REPORT_CREATED UI bildirimi' -Action {
                Write-RepairStatus -Level SUCCESS `
                    -Message (Get-RepairText `
                        -Key 'Repair.Report.Created' `
                        -Arguments @($script:RepairReportPath))
            }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
}
function Write-RepairRule {
    param(
        [ValidateSet('-', '=')]
        [string]$Character = '-'
    )
    Write-WinlamaUIRule -Character $Character
}
function Write-RepairLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-WinlamaUILine -Text $Text -Color $Color
}
function Write-RepairStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    Write-WinlamaUIStatus -Level $Level -Message $Message
}
function Read-RepairInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = ('Se{0}iminiz' -f [char]0x00E7),
        [string]$Hint = '',
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    return Read-WinlamaUIInput -Prompt $Prompt -Label $Label `
        -Hint $Hint -InputReader $InputReader `
        -NoLeadingRule:$NoLeadingRule
}
function Confirm-RepairAction {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader
    )
    return Confirm-WinlamaUIAction -Prompt $Prompt `
        -InputReader $InputReader
}
function Get-RepairOfficialModelUriPrefixes {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [string]$PropertyName = 'OfficialModelUriPrefixes'
    )
    $property = $Config.Security.PSObject.Properties[
        $PropertyName
    ]
    if ($null -eq $property -or @($property.Value).Count -eq 0) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @(
                "Security.$PropertyName"
            ))
    }
    $prefixes = @($property.Value | ForEach-Object {
        [string]$_
    })
    foreach ($prefix in $prefixes) {
        $uri = $null
        if (-not [uri]::TryCreate(
            $prefix,
            [UriKind]::Absolute,
            [ref]$uri
        ) -or $uri.Scheme -ne 'https' -or
            $uri.Host -ine 'huggingface.co' -or
            -not $prefix.EndsWith('/')) {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @(
                    "Security.$PropertyName"
                ))
        }
    }
    return $prefixes
}
function Assert-RepairModelCatalog {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string[]]$OfficialPrefixes,
        [string[]]$AuditPrefixes = @(),
        [Parameter(Mandatory)][string]$Root
    )
    foreach ($model in @($Config.ComfyUI.Catalog)) {
        foreach ($asset in @($model.Assets)) {
            $null = Resolve-RepairSafeChildPath `
                -Root (Join-Path $Root 'Models') `
                -RelativePath ([string]$asset.RelativePath)
            $assetUri = [string]$asset.Uri
            $uri = $null
            $official = $null -ne ($OfficialPrefixes |
                Where-Object {
                    $assetUri.StartsWith(
                        $_,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } | Select-Object -First 1)
            if ([string]$asset.Sha256 -notmatch `
                '^[a-fA-F0-9]{64}$' -or
                -not [uri]::TryCreate(
                    $assetUri,
                    [UriKind]::Absolute,
                    [ref]$uri
                ) -or $uri.Scheme -ne 'https' -or -not $official) {
                throw (Get-RepairText `
                    -Key 'Repair.Error.ConfigInvalid' `
                    -Arguments @("ComfyUI.$($model.Name)"))
            }
        }
    }
    if ($null -eq $Config.ComfyUI.PSObject.Properties[
        'AuditCatalog'
    ]) {
        return
    }
    foreach ($model in @($Config.ComfyUI.AuditCatalog)) {
        foreach ($asset in @($model.Assets)) {
            $null = Resolve-RepairSafeChildPath `
                -Root (Join-Path $Root 'Models') `
                -RelativePath ([string]$asset.RelativePath)
            $assetUri = [string]$asset.Uri
            $uri = $null
            $official = $null -ne ($AuditPrefixes |
                Where-Object {
                    $assetUri.StartsWith(
                        $_,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } | Select-Object -First 1)
            if ([string]$asset.Sha256 -notmatch `
                '^[a-fA-F0-9]{64}$' -or
                -not [uri]::TryCreate(
                    $assetUri,
                    [UriKind]::Absolute,
                    [ref]$uri
                ) -or $uri.Scheme -ne 'https' -or -not $official) {
                throw (Get-RepairText `
                    -Key 'Repair.Error.ConfigInvalid' `
                    -Arguments @("ComfyUI.Audit.$($model.Name)"))
            }
        }
    }
}
function Test-RepairPackageRoot {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($relativePath in @(
        'Install.ps1', 'Engine.ps1', 'Launcher.ps1',
        'ModelManager.ps1', 'Repair.ps1',
        'Data\Configs\config.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) `
            -PathType Leaf)) {
            return $false
        }
    }
    return $true
}
function Get-RepairPackageCandidates {
    $paths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    if (Test-RepairPackageRoot -Root $PSScriptRoot) {
        $null = $paths.Add(
            [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
        )
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        foreach ($relativePath in @('Software\Winlama', 'Winlama')) {
            $candidate = Join-Path $drive.Root $relativePath
            if (Test-RepairPackageRoot -Root $candidate) {
                $null = $paths.Add(
                    [IO.Path]::GetFullPath($candidate).TrimEnd('\')
                )
            }
        }
    }
    $packages = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @($paths | Sort-Object)) {
        try {
            $candidateConfig = Get-Content -LiteralPath (
                Join-Path $candidate 'Data\Configs\config.json'
            ) -Raw -Encoding UTF8 | ConvertFrom-RepairJson
            $installedRoot = Resolve-RepairPath `
                -Path ([string]$candidateConfig.Paths.Root) `
                -BasePath $candidate
            if ($installedRoot -ine $candidate) {
                $packages.Add($candidate)
            }
        }
        catch {
            Write-Verbose (Get-RepairText `
                -Key 'Repair.Verbose.CandidateSkipped' `
                -Arguments @($candidate, $_.Exception.Message))
        }
    }
    return $packages.ToArray()
}
function Show-RepairPackageSelection {
    param([Parameter(Mandatory)][string[]]$Candidates)
    if ($Candidates.Count -lt 2) {
        throw 'Onarim kaynak secim ekrani en az iki aday gerektirir.'
    }
    Write-RepairRule
    Write-RepairLine -Text (Get-RepairText `
        -Key 'Repair.Source.Select') -Color Cyan
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        Write-RepairLine -Text (Get-RepairText `
            -Key 'Repair.Source.CandidateRow' `
            -Arguments @(($index + 1), $Candidates[$index]))
    }
    Write-RepairRule
}
function Select-RepairPackageRoot {
    param(
        [string]$RequestedRoot,
        [string]$RecordedRoot,
        [string[]]$Candidates,
        [switch]$AllowPathInput,
        [switch]$NonInteractive,
        [scriptblock]$InputReader
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $resolved = Resolve-RepairPath -Path $RequestedRoot
        if (-not (Test-RepairPackageRoot -Root $resolved)) {
            throw (Get-RepairText -Key 'Repair.Error.SourceInvalid' `
                -Arguments @($resolved))
        }
        return $resolved
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordedRoot)) {
        try {
            $recorded = Resolve-RepairPath -Path $RecordedRoot
            if ((Test-RepairPackageRoot -Root $recorded) -and
                (Test-RepairManagedConfigurationSafe -Path (
                    Resolve-RepairConfigPath -Root $recorded
                ))) {
                return $recorded
            }
        }
        catch {
            Write-Verbose (Get-RepairText -Key 'Repair.Verbose.CandidateSkipped' `
                -Arguments @($RecordedRoot, $_.Exception.Message))
        }
    }
    $candidates = if ($null -eq $Candidates) {
        @(Get-RepairPackageCandidates)
    }
    else {
        @($Candidates)
    }
    if ($candidates.Count -eq 0) {
        if ($AllowPathInput) {
            $path = Read-RepairInput -Prompt (Get-RepairText `
                -Key 'Repair.Prompt.SourcePath') -InputReader $InputReader
            return Select-RepairPackageRoot -RequestedRoot $path `
                -Candidates @()
        }
        throw (Get-RepairText -Key 'Repair.Error.SourceMissing')
    }
    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }
    if ($NonInteractive) {
        throw (Get-RepairText -Key 'Repair.Error.SourceRequired')
    }
    Show-RepairPackageSelection -Candidates $candidates
    while ($true) {
        $selection = Read-RepairInput -Prompt (Get-RepairText `
            -Key 'Common.Prompt.Selection') -InputReader $InputReader `
            -NoLeadingRule
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and
            $selectedIndex -le $candidates.Count) {
            return $candidates[$selectedIndex - 1]
        }
        Write-RepairStatus -Level WARN -Message (Get-RepairText `
            -Key 'Common.Selection.Invalid')
    }
}
function Assert-RepairDestination {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $driveRoot = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    if ($resolved -ieq $driveRoot -or
        [IO.Path]::GetFileName($resolved) -ine 'Winlama') {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @($resolved))
    }
    $protectedRoots = @(
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::Windows
        ),
        [Environment]::SystemDirectory,
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::ProgramFiles
        ),
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::ProgramFilesX86
        ),
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::CommonApplicationData
        )
    )
    foreach ($protectedRoot in @($protectedRoots | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })) {
        $protected = [IO.Path]::GetFullPath($protectedRoot).
            TrimEnd('\')
        if ($resolved -ieq $protected -or $resolved.StartsWith(
            $protected + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
                -Arguments @($resolved))
        }
    }
    Assert-RepairNoReparsePoint -Path $resolved
}
function Resolve-RepairDestinationRoot {
    param(
        [string]$RequestedRoot,
        [scriptblock]$InputReader
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $resolved = Resolve-RepairPath -Path $RequestedRoot
        Assert-RepairDestination -Path $resolved
        return $resolved
    }
    while ($true) {
        $value = Read-RepairInput -Prompt (Get-RepairText `
            -Key 'Repair.Prompt.Destination') `
            -Label (Get-RepairText `
                -Key 'Repair.Prompt.DestinationLabel') `
            -InputReader $InputReader
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-RepairStatus -Level WARN -Message (Get-RepairText `
                -Key 'Common.Selection.Invalid')
            continue
        }
        try {
            $resolved = Resolve-RepairPath -Path $value
            Assert-RepairDestination -Path $resolved
            return $resolved
        }
        catch {
            Write-RepairStatus -Level WARN -Message $_.Exception.Message
        }
    }
}
function Resolve-RepairSafeChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if ([IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
            -Arguments @($RelativePath, $Root))
    }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path $fullRoot $RelativePath)
    )
    if (-not $fullPath.StartsWith(
        $fullRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
            -Arguments @($fullPath, $fullRoot))
    }
    return $fullPath
}
function Get-RepairRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
            -Arguments @($resolved, $prefix))
    }
    return $resolved.Substring($prefix.Length)
}
function Test-RepairPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith(
        $fullRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
}
function Assert-RepairNoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ItemProvider
    )
    if ($null -eq $ItemProvider) {
        $ItemProvider = {
            param([string]$Candidate)
            if (-not (Test-Path -LiteralPath $Candidate)) {
                return $null
            }
            return Get-Item -LiteralPath $Candidate -Force `
                -ErrorAction Stop
        }
    }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($pathRoot.Length)
    $current = $pathRoot
    foreach ($segment in @($relative.Split('\') | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })) {
        $current = Join-Path $current $segment
        $item = & $ItemProvider $current
        if ($null -ne $item -and
            ([IO.FileAttributes]$item.Attributes -band
                [IO.FileAttributes]::ReparsePoint)) {
            throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
                -Arguments @($current))
        }
    }
}
function Assert-RepairSafeTreePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-RepairPathWithinRoot -Root $Root -Path $Path)) {
        throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
            -Arguments @($Path, $Root))
    }
    Assert-RepairNoReparsePoint -Path $Root
    Assert-RepairNoReparsePoint -Path $Path
}
function Assert-RepairRootsDisjoint {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $targetRoot = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($sourceRoot -ieq $targetRoot -or
        $sourceRoot.StartsWith(
            $targetRoot + '\',
            [StringComparison]::OrdinalIgnoreCase
        ) -or $targetRoot.StartsWith(
            $sourceRoot + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
            -Arguments @($targetRoot, $sourceRoot))
    }
}
function Get-RepairSafeTreeFiles {
    param([Parameter(Mandatory)][string]$Root)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $attributesProvider = {
        param([string]$Candidate)
        return @{ Attributes = [IO.File]::GetAttributes($Candidate) }
    }
    $prefix = $fullRoot + '\'
    $directories = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $directories.Enqueue([IO.DirectoryInfo]::new($fullRoot))
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        Assert-RepairNoReparsePoint -Path $directory.FullName `
            -ItemProvider $attributesProvider
        foreach ($item in $directory.EnumerateFileSystemInfos()) {
            if (-not $item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw (Get-RepairText -Key 'Repair.Error.PathOutsideScope' `
                    -Arguments @($item.FullName, $fullRoot))
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
                    -Arguments @($item.FullName))
            }
            if ($item -is [IO.DirectoryInfo]) {
                $directories.Enqueue($item)
            }
            else {
                $files.Add([IO.FileInfo]$item)
            }
        }
    }
    return $files.ToArray()
}
function Get-RepairCanonicalComfyUIPath {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @('%LOCALAPPDATA%\Programs\ComfyUI'))
    }
    return [IO.Path]::GetFullPath(
        (Join-Path $localAppData 'Programs\ComfyUI')
    ).TrimEnd('\')
}
function Get-RepairCanonicalUserModelPath {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ComfyUI', 'Ollama')]
        [string]$Kind
    )
    $userProfile = [Environment]::ExpandEnvironmentVariables(
        '%USERPROFILE%'
    )
    if ([string]::IsNullOrWhiteSpace($userProfile) -or
        $userProfile.Contains('%') -or
        -not [IO.Path]::IsPathRooted($userProfile)) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @('%USERPROFILE%'))
    }
    $relative = if ($Kind -eq 'ComfyUI') {
        '.comfyui\models'
    }
    else {
        '.ollama\models'
    }
    return [IO.Path]::GetFullPath(
        (Join-Path $userProfile $relative)
    ).TrimEnd('\')
}
function Resolve-RepairCanonicalModelPath {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('ComfyUI', 'Ollama')]
        [string]$Kind,
        [string]$CanonicalPath
    )
    $configured = if ($Kind -eq 'ComfyUI') {
        [string]$Config.ComfyUI.ModelsPath
    }
    else {
        [string]$Config.Paths.Models
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @("$Kind.ModelsPath"))
    }
    $candidate = Resolve-RepairPath -Path $configured
    $expected = if ([string]::IsNullOrWhiteSpace($CanonicalPath)) {
        Get-RepairCanonicalUserModelPath -Kind $Kind
    }
    else {
        [IO.Path]::GetFullPath($CanonicalPath).TrimEnd('\')
    }
    if ($candidate -ine $expected) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @($candidate))
    }
    Assert-RepairNoReparsePoint -Path $candidate
    return $candidate
}
function Assert-RepairCanonicalModelPaths {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$PackageRoot
    )
    $packageModels = Join-Path $PackageRoot 'Models'
    Assert-RepairNoReparsePoint -Path $PackageRoot
    Assert-RepairNoReparsePoint -Path $packageModels
    foreach ($kind in @('ComfyUI', 'Ollama')) {
        $modelPath = Resolve-RepairCanonicalModelPath `
            -Config $Config -Kind $kind
        Assert-RepairRootsDisjoint -Source $packageModels `
            -Target $modelPath
    }
}
function Resolve-RepairComfyUIInstallTarget {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][string]$SourceRuntime,
        [string]$CanonicalPath
    )
    if ($null -eq $Config.ComfyUI -or
        [string]::IsNullOrWhiteSpace(
            [string]$Config.ComfyUI.InstallPath
        )) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @('ComfyUI.InstallPath'))
    }
    $candidate = Resolve-RepairPath `
        -Path ([string]$Config.ComfyUI.InstallPath) `
        -BasePath $InstalledRoot
    $expected = if ([string]::IsNullOrWhiteSpace($CanonicalPath)) {
        Get-RepairCanonicalComfyUIPath
    }
    else {
        [IO.Path]::GetFullPath($CanonicalPath).TrimEnd('\')
    }
    if ($candidate -ine $expected -or
        [IO.Path]::GetFileName($candidate) -ine 'ComfyUI') {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @($candidate))
    }
    Assert-RepairRootsDisjoint -Source $SourceRuntime `
        -Target $candidate
    Assert-RepairNoReparsePoint -Path $SourceRuntime
    Assert-RepairNoReparsePoint -Path $candidate
    return $candidate
}
function Test-RepairComfyUIRuntimeLayout {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path `
        'python_embeded\python.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
        'ComfyUI\main.py') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
        'run_nvidia_gpu_fast_fp16_accumulation.bat') -PathType Leaf)
}
function Test-RepairComfyUICoreRelativePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('/', '\').TrimStart('\')
    if ($relative -ieq '.winlama-runtime.json' -or
        $relative.StartsWith(
            '.winlama\',
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $relative -ieq 'ComfyUI\extra_model_paths.yaml' -or
        $relative -match '(^|[\\/])__pycache__([\\/]|$)' -or
        [IO.Path]::GetExtension($relative) -iin @('.pyc', '.pyo')) {
        return $false
    }
    foreach ($prefix in @(
        'ComfyUI\custom_nodes\',
        'ComfyUI\input\',
        'ComfyUI\output\',
        'ComfyUI\temp\',
        'ComfyUI\user\',
        'python_embeded\Lib\site-packages\',
        'python_embeded\Scripts\',
        'WinlamaLogs\'
    )) {
        if ($relative.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }
    }
    return $true
}
function Get-RepairComfyUICoreIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-RepairSafeTreeFiles -Root $root) {
        $relative = $file.FullName.Substring($root.Length).
            TrimStart('\')
        if (-not (Test-RepairComfyUICoreRelativePath `
            -RelativePath $relative)) {
            continue
        }
        $fileHash = (Get-FileHash -LiteralPath $file.FullName `
            -Algorithm SHA256).Hash.ToUpperInvariant()
        $entries.Add(('{0}|{1}|{2}' -f `
            $relative.Replace('\', '/'),
            [long]$file.Length,
            $fileHash
        ))
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
    return [pscustomobject]@{
        FileCount = $entries.Count
        Sha256 = [BitConverter]::ToString($hash).Replace('-', '')
    }
}
function Test-RepairComfyUIRuntimeMarker {
    param(
        [AllowNull()][object]$Marker,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$CoreIdentity
    )
    if ($null -eq $Marker -or $null -eq $Config.ComfyUI) {
        return $false
    }
    foreach ($property in @(
        'SchemaVersion', 'PortableVersion', 'ArchiveSha256',
        'ArchiveSizeBytes', 'CoreFileCount', 'CoreSha256'
    )) {
        if ($null -eq $Marker.PSObject.Properties[$property]) {
            return $false
        }
    }
    foreach ($property in @(
        'PortableVersion', 'PortableSha256', 'PortableSizeBytes'
    )) {
        if ($null -eq $Config.ComfyUI.PSObject.Properties[$property]) {
            return $false
        }
    }
    try {
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
    catch {
        return $false
    }
}
function Get-RepairComfyUIRuntimeAssessment {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{
            Valid = $false
            Reason = 'runtime dizini yok'
        }
    }
    if (-not (Test-RepairComfyUIRuntimeLayout -Path $Path)) {
        return [pscustomobject]@{
            Valid = $false
            Reason = 'zorunlu runtime dosyalari eksik'
        }
    }
    $markerPath = Join-Path $Path '.winlama-runtime.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return [pscustomobject]@{
            Valid = $false
            Reason = '.winlama-runtime.json yok'
        }
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw `
            -Encoding UTF8 | ConvertFrom-RepairJson
        $identity = Get-RepairComfyUICoreIdentity -Path $Path
        if (-not (Test-RepairComfyUIRuntimeMarker `
            -Marker $marker -Config $Config `
            -CoreIdentity $identity)) {
            return [pscustomobject]@{
                Valid = $false
                Reason = 'surum veya cekirdek kimligi uyusmuyor'
            }
        }
        return [pscustomobject]@{
            Valid = $true
            Reason = 'exact runtime kimligi dogrulandi'
        }
    }
    catch {
        return [pscustomobject]@{
            Valid = $false
            Reason = 'runtime kimligi okunamadi: {0}' -f `
                $_.Exception.Message
        }
    }
}
function Assert-RepairComfyUIRuntimeContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    foreach ($property in @(
        'PortableVersion', 'PortableSha256', 'PortableSizeBytes'
    )) {
        if ($null -eq $Config.ComfyUI.PSObject.Properties[$property]) {
            throw "ComfyUI runtime yapilandirmasi eksik: $property"
        }
    }
    if ([string]::IsNullOrWhiteSpace(
        [string]$Config.ComfyUI.PortableVersion
    ) -or [string]$Config.ComfyUI.PortableSha256 -notmatch
        '^[a-fA-F0-9]{64}$' -or
        [long]$Config.ComfyUI.PortableSizeBytes -le 0) {
        throw 'ComfyUI exact runtime yapilandirmasi gecersiz.'
    }
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
    if (-not (Test-RepairComfyUIRuntimeMarker `
        -Marker $current -Config $Config -CoreIdentity $identity)) {
        throw 'Guncel ComfyUI runtime kimligi reddedildi.'
    }
    $old = $current | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $old.PortableVersion = '0.30.0'
    if (Test-RepairComfyUIRuntimeMarker `
        -Marker $old -Config $Config -CoreIdentity $identity) {
        throw 'Eski ComfyUI runtime kimligi kabul edildi.'
    }
    if (Test-RepairComfyUIRuntimeMarker `
        -Marker $null -Config $Config -CoreIdentity $identity) {
        throw 'Markersiz ComfyUI runtime kimligi kabul edildi.'
    }
    $corrupt = $current | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $corrupt.CoreSha256 = 'B' * 64
    if (Test-RepairComfyUIRuntimeMarker `
        -Marker $corrupt -Config $Config -CoreIdentity $identity) {
        throw 'Bozuk ComfyUI runtime cekirdegi kabul edildi.'
    }
    if (-not (Test-RepairComfyUICoreRelativePath `
        -RelativePath 'run_nvidia_gpu_fast_fp16_accumulation.bat') -or
        (Test-RepairComfyUICoreRelativePath `
            -RelativePath '.winlama\state.json')) {
        throw 'ComfyUI cekirdek kapsam sozlesmesi gecersiz.'
    }
    $fixtureRoot = 'C:\Fixture\Runtime'
    if (-not (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path "$fixtureRoot\ComfyUI\main.py") -or
        -not (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path ($fixtureRoot +
                '\ComfyUI\tests\execution\extra_model_paths.yaml')) -or
        (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path "$fixtureRoot\ComfyUI\extra_model_paths.yaml") -or
        (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path "$fixtureRoot\python_embeded\module.pyc") -or
        (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path "$fixtureRoot\python_embeded\module.pyo") -or
        (Test-RepairRuntimeFile -Root $fixtureRoot `
            -Path ($fixtureRoot +
                '\python_embeded\__pycache__\module.pyc'))) {
        throw 'ComfyUI runtime temizlik kapsam sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.ComfyUIRuntimeIdentity'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.RuntimePayloadCleanliness'
}
function Sync-RepairTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Mirror,
        [switch]$Optional,
        [switch]$RuntimePayload,
        [switch]$InstalledRuntimeTarget,
        [pscustomobject]$RuntimeConfig
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        if ($Optional) {
            $message = Get-RepairText `
                -Key 'Repair.Verbose.OptionalMissing' `
                -Arguments @($Source)
            Write-Verbose $message
            $script:DifferentCount++
            Add-RepairUnresolved -Message $message
            Add-RepairSkipped -Message (Get-RepairText `
                -Key 'Repair.Skipped.OptionalSource' `
                -Arguments @($Source))
            return
        }
        throw (Get-RepairText -Key 'Repair.Error.SourceTreeMissing' `
            -Arguments @($Source))
    }
    Assert-RepairRootsDisjoint -Source $Source -Target $Target
    Assert-RepairNoReparsePoint -Path $Source
    Assert-RepairNoReparsePoint -Path $Target
    if ($RuntimePayload) {
        if ($null -eq $RuntimeConfig) {
            throw 'ComfyUI runtime yapilandirmasi belirtilmedi.'
        }
        if ($InstalledRuntimeTarget) {
            $canonicalTarget = Resolve-RepairComfyUIInstallTarget `
                -Config $RuntimeConfig `
                -InstalledRoot (Split-Path -Parent $Target) `
                -SourceRuntime $Source
            if ($canonicalTarget -ine
                [IO.Path]::GetFullPath($Target).TrimEnd('\')) {
                throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
                    -Arguments @($Target))
            }
        }
        $sourceAssessment = Get-RepairComfyUIRuntimeAssessment `
            -Path $Source -Config $RuntimeConfig
        if (-not $sourceAssessment.Valid) {
            $script:DifferentCount++
            $message = Get-RepairText `
                -Key 'Repair.ComfyUI.SourceRejected' `
                -Arguments @($Source, $sourceAssessment.Reason)
            Write-RepairStatus -Level WARN -Message $message
            Write-RepairLog -Event 'COMFYUI_RUNTIME_SOURCE_REJECTED' `
                -Message $message -Level WARN `
                -Data @{ Source = $Source;
                    Reason = $sourceAssessment.Reason }
            Add-RepairUnresolved -Message $message
            return
        }
        $targetAssessment = Get-RepairComfyUIRuntimeAssessment `
            -Path $Target -Config $RuntimeConfig
        if (-not $targetAssessment.Valid) {
            Write-RepairStatus -Level WARN -Message (
                Get-RepairText `
                    -Key 'Repair.ComfyUI.TargetRepairNeeded' `
                    -Arguments @($Target, $targetAssessment.Reason)
            )
        }
    }
    $sourceFiles = @(Get-RepairSafeTreeFiles -Root $Source)
    $targetFiles = if (Test-Path -LiteralPath $Target `
        -PathType Container) {
        @(Get-RepairSafeTreeFiles -Root $Target)
    }
    else {
        @()
    }
    if ($RuntimePayload) {
        $sourceFiles = @($sourceFiles | Where-Object {
            Test-RepairRuntimeFile -Root $Source -Path $_.FullName
        })
        $targetFiles = @($targetFiles | Where-Object {
            if (-not (Test-RepairRuntimeFile `
                -Root $Target -Path $_.FullName)) {
                return $false
            }
            $relative = Get-RepairRelativePath `
                -Root $Target -Path $_.FullName
            return $relative -ieq '.winlama-runtime.json' -or
                (Test-RepairComfyUICoreRelativePath `
                    -RelativePath $relative)
        })
        Write-RepairLog -Event 'COMFYUI_RUNTIME_SOURCE_VERIFIED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.ComfyUIRuntimeVerified') `
            -Data @{ Source = $Source;
                PortableVersion = $RuntimeConfig.ComfyUI.PortableVersion }
    }
    Write-Verbose (Get-RepairText -Key 'Repair.Verbose.Scope' `
        -Arguments @($Source, $Target, $sourceFiles.Count))
    Sync-RepairFileSet -SourceBase $Source -TargetBase $Target `
        -SourceFiles $sourceFiles -TargetFiles $targetFiles `
        -Mirror:($Mirror -or $RuntimePayload)
    if ($RuntimePayload -and $Apply -and -not $WhatIfPreference) {
        $result = Get-RepairComfyUIRuntimeAssessment `
            -Path $Target -Config $RuntimeConfig
        if (-not $result.Valid) {
            throw ('ComfyUI runtime hedef dogrulamasi basarisiz: {0} | {1}' `
                -f $Target, $result.Reason)
        }
        Write-RepairLog -Event 'COMFYUI_RUNTIME_VERIFIED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.ComfyUICoreVerified') `
            -Data @{ Target = $Target;
                PortableVersion = $RuntimeConfig.ComfyUI.PortableVersion }
    }
}
function Test-RepairRuntimeFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $relative = Get-RepairRelativePath -Root $Root -Path $Path
    $segments = @($relative.Replace('/', '\').Split('\'))
    foreach ($segment in $segments) {
        if ($segment -iin @(
            '__pycache__', '.git', '.winlama', 'custom_nodes',
            'input', 'output', 'temp', 'user', 'Logs', 'Reports',
            'WinlamaLogs'
        )) {
            return $false
        }
    }
    $extension = [IO.Path]::GetExtension($relative)
    if ($relative -ieq 'ComfyUI\extra_model_paths.yaml' -or
        $extension -iin @('.pyc', '.pyo')) {
        return $false
    }
    return $extension -inotmatch '^\.(log|tmp|part)$'
}
function Get-RepairApplicationFiles {
    param([Parameter(Mandatory)][string]$Root)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    if (Test-Path -LiteralPath $Root -PathType Container) {
        Assert-RepairNoReparsePoint -Path $Root
        foreach ($file in @(Get-ChildItem -LiteralPath $Root `
            -File -Force | Where-Object {
                $_.Extension -in @('.ps1', '.bat')
            })) {
            Assert-RepairSafeTreePath -Root $Root `
                -Path $file.FullName
            $files.Add($file)
        }
    }
    foreach ($relativePath in @(
        'Modules', 'Services', 'String',
        'Data\Configs', 'Data\Workflows'
    )) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-RepairSafeTreeFiles -Root $path)) {
            $files.Add($file)
        }
    }
    return $files.ToArray()
}
function Test-RepairManagedValueSafe {
    param(
        [AllowNull()][object]$Value,
        [string]$PropertyName = ''
    )
    if ($null -eq $Value) {
        return $true
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if (-not (Test-RepairManagedValueSafe `
                -Value $Value[$key] -PropertyName ([string]$key))) {
                return $false
            }
        }
        return $true
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (-not (Test-RepairManagedValueSafe `
                -Value $property.Value `
                -PropertyName ([string]$property.Name))) {
                return $false
            }
        }
        return $true
    }
    if ($Value -is [Collections.IEnumerable] -and
        $Value -isnot [string]) {
        foreach ($item in $Value) {
            if (-not (Test-RepairManagedValueSafe `
                -Value $item -PropertyName $PropertyName)) {
                return $false
            }
        }
        return $true
    }
    $text = [string]$Value
    if ($PropertyName -match `
        '(?i)(^|[._-])(api[_-]?key|password|secret|token|' +
        'access[_-]?token|authorization|credential)$' -and
        -not [string]::IsNullOrWhiteSpace($text)) {
        return $false
    }
    return $text -notmatch `
        '(?i)([A-Z]:[\\/]Users[\\/][^\\/]+[\\/]|' +
        '/(?:home|Users)/[^/]+/)'
}
function Test-RepairManagedConfigurationSafe {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $document = Get-Content -LiteralPath $Path -Raw `
            -Encoding UTF8 | ConvertFrom-RepairJson
        return Test-RepairManagedValueSafe -Value $document
    }
    catch {
        Write-Verbose ('Yonetilen yapilandirma denetlenemedi: {0} | {1}' `
            -f $Path, $_.Exception.Message)
        return $false
    }
}
function Test-RepairApplicationPayloadRelativePath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$PackageTarget
    )
    $normalized = $RelativePath.Replace('/', '\')
    return $normalized -inotmatch `
        '^Data\\Configs\\(config|managed-payload)\.json$'
}
function Sync-RepairApplicationPayload {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$PackageTarget,
        [switch]$Execute,
        [scriptblock]$ApplicationFileProvider,
        [scriptblock]$HashProvider,
        [scriptblock]$CopyHandler
    )
    Assert-RepairDestination -Path $Target
    Assert-RepairRootsDisjoint -Source $Source -Target $Target
    if ($null -eq $ApplicationFileProvider) {
        $ApplicationFileProvider = {
            param([string]$Root)
            Get-RepairApplicationFiles -Root $Root
        }
    }
    if ($null -eq $HashProvider) {
        $HashProvider = {
            param([string]$Path)
            Get-RepairHash -Path $Path
        }
    }
    if ($null -eq $CopyHandler) {
        $CopyHandler = {
            param(
                [string]$SourcePath,
                [string]$DestinationPath,
                [string]$ExpectedHash
            )
            Copy-RepairFile -Source $SourcePath `
                -Destination $DestinationPath `
                -ExpectedHash $ExpectedHash
        }
    }
    $sourceFiles = @(& $ApplicationFileProvider $Source)
    $targetFiles = @(& $ApplicationFileProvider $Target)
    $sourceMap = @{}
    $targetMap = @{}
    foreach ($file in $sourceFiles) {
        $relative = Get-RepairRelativePath -Root $Source `
            -Path $file.FullName
        if (-not (Test-RepairApplicationPayloadRelativePath `
            -RelativePath $relative -PackageTarget:$PackageTarget)) {
            continue
        }
        $sourceMap[$relative] = $file
    }
    foreach ($file in $targetFiles) {
        $relative = Get-RepairRelativePath -Root $Target `
            -Path $file.FullName
        if (-not (Test-RepairApplicationPayloadRelativePath `
            -RelativePath $relative -PackageTarget:$PackageTarget)) {
            continue
        }
        $targetMap[$relative] = $file
    }
    foreach ($relative in @($sourceMap.Keys | Sort-Object)) {
        $sourceFile = $sourceMap[$relative]
        $destination = Join-Path $Target $relative
        Assert-RepairSafeTreePath -Root $Source `
            -Path $sourceFile.FullName
        Assert-RepairSafeTreePath -Root $Target `
            -Path $destination
        if ($relative.StartsWith(
            'Data\Configs\',
            [StringComparison]::OrdinalIgnoreCase
        ) -and [IO.Path]::GetExtension($relative) -ieq '.json' -and
            -not (Test-RepairManagedConfigurationSafe `
                -Path $sourceFile.FullName)) {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @($relative))
        }
        $sourceHash = [string](& $HashProvider $sourceFile.FullName)
        if (-not $targetMap.ContainsKey($relative)) {
            $script:DifferentCount++
            Write-RepairStatus -Level STEP -Message (Get-RepairText `
                -Key 'Repair.File.Different' `
                -Arguments @($destination))
            if ($Execute) {
                & $CopyHandler $sourceFile.FullName `
                    $destination $sourceHash
                if (-not $WhatIfPreference) {
                    $script:ResolvedCount++
                }
            }
            else {
                Add-RepairUnresolved -Message (Get-RepairText `
                    -Key 'Repair.Unresolved.File' `
                    -Arguments @($destination))
            }
            continue
        }
        $targetFile = $targetMap[$relative]
        $targetHash = [string](& $HashProvider $targetFile.FullName)
        if ($sourceHash -eq $targetHash) {
            $script:MatchedCount++
            continue
        }
        $script:DifferentCount++
        Write-RepairStatus -Level STEP -Message (Get-RepairText `
            -Key 'Repair.File.Different' `
            -Arguments @($targetFile.FullName))
        Write-RepairLog -Event 'APPLICATION_PACKAGE_SELECTED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.CanonicalSourceSelected') `
            -Data @{ RelativePath = $relative;
                SourceSha256 = $sourceHash;
                TargetSha256 = $targetHash }
        if ($Execute) {
            & $CopyHandler $sourceFile.FullName `
                $targetFile.FullName $sourceHash
            if (-not $WhatIfPreference) {
                $script:ResolvedCount++
            }
        }
        else {
            Add-RepairUnresolved -Message (Get-RepairText `
                -Key 'Repair.Unresolved.File' `
                -Arguments @($targetFile.FullName))
        }
    }
    foreach ($relative in @($targetMap.Keys | Sort-Object)) {
        if ($sourceMap.ContainsKey($relative)) {
            continue
        }
        $targetFile = $targetMap[$relative]
        Assert-RepairSafeTreePath -Root $Target `
            -Path $targetFile.FullName
        $script:DifferentCount++
        Write-RepairStatus -Level WARN -Message (Get-RepairText `
            -Key 'Repair.File.Extra' `
            -Arguments @($targetFile.FullName))
        Write-RepairLog -Event 'APPLICATION_TARGET_PRESERVED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.UnknownTargetPreserved') `
            -Level WARN -Data @{ RelativePath = $relative;
                Path = $targetFile.FullName }
        $message = Get-RepairText -Key 'Repair.Skipped.UnknownTarget' `
            -Arguments @($targetFile.FullName)
        Add-RepairSkipped -Message $message
        Add-RepairUnresolved -Message $message
    }
}
function Sync-RepairCanonicalPackageConfig {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Execute
    )
    $relative = 'Data\Configs\config.json'
    $sourcePath = Join-Path $Source $relative
    $targetPath = Join-Path $Target $relative
    if (-not (Test-RepairManagedConfigurationSafe `
        -Path $sourcePath)) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @($relative))
    }
    $expectedHash = Get-RepairHash -Path $sourcePath
    if (Test-RepairFileHash -Path $targetPath `
        -ExpectedHash $expectedHash) {
        $script:MatchedCount++
        return
    }
    $script:DifferentCount++
    Write-RepairStatus -Level STEP -Message (Get-RepairText `
        -Key 'Repair.File.Different' -Arguments @($targetPath))
    if ($Execute) {
        Copy-RepairFile -Source $sourcePath -Destination $targetPath `
            -ExpectedHash $expectedHash
        if (-not $WhatIfPreference) {
            $script:ResolvedCount++
        }
    }
    else {
        Add-RepairUnresolved -Message (Get-RepairText `
            -Key 'Repair.Unresolved.File' -Arguments @($targetPath))
    }
}
function Assert-RepairApplicationSafetyContract {
    $safeConfiguration = [pscustomobject]@{
        Services = @(
            [pscustomobject]@{
                Name = 'ComfyUI'
                Credentials = [pscustomobject]@{
                    api_key = ''
                    token = ''
                }
            }
        )
    }
    $secretConfiguration = [pscustomobject]@{
        Services = @(
            [pscustomobject]@{
                Credentials = [pscustomobject]@{
                    api_key = 'private-value'
                }
            }
        )
    }
    $personalPathConfiguration = [pscustomobject]@{
        Services = [pscustomobject]@{
            Cache = 'C:\Users\Example\private-cache'
        }
    }
    if (-not (Test-RepairManagedValueSafe `
        -Value $safeConfiguration) -or
        (Test-RepairManagedValueSafe -Value $secretConfiguration) -or
        (Test-RepairManagedValueSafe `
            -Value $personalPathConfiguration)) {
        throw 'Ic ice onarim yapilandirma guvenlik testi basarisiz.'
    }
    foreach ($statePath in @(
        'Data\Configs\config.json',
        'Data\Configs\managed-payload.json'
    )) {
        if ((Test-RepairApplicationPayloadRelativePath `
            -RelativePath $statePath) -or
            (Test-RepairApplicationPayloadRelativePath `
                -RelativePath $statePath -PackageTarget)) {
            throw "Kurulu yapilandirma koruma kapsami gecersiz: $statePath"
        }
    }
    $repairAllPolicy = Get-RepairExecutionPolicy `
        -SelectedMode RepairAll
    if ($repairAllPolicy.ModelAuditOnly -or
        -not $repairAllPolicy.InvokeInstaller -or
        $repairAllPolicy.ModelDirection -ne 'Bidirectional') {
        throw 'Iki tarafli gercek onarim ilkesi gecersiz.'
    }
    $driveRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath($PSScriptRoot)
    )
    $sourceRoot = Join-Path $driveRoot `
        'WinlamaValidation\CanonicalSource'
    $targetRoot = Join-Path $driveRoot `
        'WinlamaValidation\Installed\Winlama'
    $sourceFiles = @(
        [pscustomobject]@{
            FullName = Join-Path $sourceRoot 'Modules\Same.psm1'
        }
        [pscustomobject]@{
            FullName = Join-Path $sourceRoot 'Modules\Changed.psm1'
        }
        [pscustomobject]@{
            FullName = Join-Path $sourceRoot 'Modules\Missing.psm1'
        }
        [pscustomobject]@{
            FullName = Join-Path $sourceRoot `
                'Data\Configs\config.json'
        }
        [pscustomobject]@{
            FullName = Join-Path $sourceRoot `
                'Data\Configs\managed-payload.json'
        }
    )
    $targetFiles = @(
        [pscustomobject]@{
            FullName = Join-Path $targetRoot 'Modules\Same.psm1'
        }
        [pscustomobject]@{
            FullName = Join-Path $targetRoot 'Modules\Changed.psm1'
        }
        [pscustomobject]@{
            FullName = Join-Path $targetRoot 'Services\Unknown.py'
        }
        [pscustomobject]@{
            FullName = Join-Path $targetRoot `
                'Data\Configs\config.json'
        }
        [pscustomobject]@{
            FullName = Join-Path $targetRoot `
                'Data\Configs\managed-payload.json'
        }
    )
    $hashes = @{}
    $hashes[$sourceFiles[0].FullName] = 'same'
    $hashes[$sourceFiles[1].FullName] = 'canonical'
    $hashes[$sourceFiles[2].FullName] = 'missing'
    $hashes[$sourceFiles[3].FullName] = 'package-config'
    $hashes[$sourceFiles[4].FullName] = 'package-state'
    $hashes[$targetFiles[0].FullName] = 'same'
    $hashes[$targetFiles[1].FullName] = 'installed'
    $hashes[$targetFiles[2].FullName] = 'unknown'
    $hashes[$targetFiles[3].FullName] = 'installed-config'
    $hashes[$targetFiles[4].FullName] = 'installed-state'
    $copies = [Collections.Generic.List[object]]::new()
    $fileProvider = {
        param([string]$Root)
        if ($Root -ieq $sourceRoot) {
            return $sourceFiles
        }
        if ($Root -ieq $targetRoot) {
            return $targetFiles
        }
        return @()
    }
    $hashProvider = {
        param([string]$Path)
        return [string]$hashes[$Path]
    }
    $copyHandler = {
        param(
            [string]$SourcePath,
            [string]$DestinationPath,
            [string]$ExpectedHash
        )
        $null = $copies.Add([pscustomobject]@{
            Source = $SourcePath
            Destination = $DestinationPath
            Sha256 = $ExpectedHash
        })
    }
    $matched = $script:MatchedCount
    $different = $script:DifferentCount
    $resolved = $script:ResolvedCount
    $copied = $script:CopiedCount
    $deleted = $script:DeletedCount
    $unresolved = @($script:UnresolvedItems)
    $skipped = @($script:SkippedItems)
    try {
        Sync-RepairApplicationPayload -Source $sourceRoot `
            -Target $targetRoot -Execute `
            -ApplicationFileProvider $fileProvider `
            -HashProvider $hashProvider -CopyHandler $copyHandler
        if ($copies.Count -ne 2 -or
            $script:MatchedCount -ne ($matched + 1) -or
            $script:DifferentCount -ne ($different + 3) -or
            $script:ResolvedCount -ne ($resolved + 2) -or
            $script:SkippedItems.Count -ne ($skipped.Count + 1)) {
            throw 'Kanonik onarim uzlastirma sayaclari gecersiz.'
        }
        foreach ($copy in $copies) {
            if (-not $copy.Source.StartsWith(
                $sourceRoot + '\',
                [StringComparison]::OrdinalIgnoreCase
            ) -or -not $copy.Destination.StartsWith(
                $targetRoot + '\',
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Onarim yonu paket kaynaktan hedefe olmali.'
            }
        }
        if ($copies.Destination -contains $targetFiles[2].FullName -or
            $copies.Source -contains $targetFiles[2].FullName -or
            $copies.Destination -contains $targetFiles[3].FullName -or
            $copies.Destination -contains $targetFiles[4].FullName) {
            throw 'Bilinmeyen hedef dosya uzlastirmaya alinmamali.'
        }
    }
    finally {
        $script:MatchedCount = $matched
        $script:DifferentCount = $different
        $script:ResolvedCount = $resolved
        $script:CopiedCount = $copied
        $script:DeletedCount = $deleted
        $script:UnresolvedItems.Clear()
        foreach ($item in $unresolved) {
            $script:UnresolvedItems.Add($item)
        }
        $script:SkippedItems.Clear()
        foreach ($item in $skipped) {
            $script:SkippedItems.Add($item)
        }
    }
}
function Assert-RepairApplyPostValidationContract {
    $driveRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath($PSScriptRoot)
    )
    $sourceRoot = Join-Path $driveRoot `
        'WinlamaValidation\ApplySource'
    $targetRoot = Join-Path $driveRoot `
        'WinlamaValidation\ApplyTarget\Winlama'
    $sourceState = @{}
    $targetState = @{}
    foreach ($relative in @(
        'Modules\Changed.psm1', 'Services\Missing.py'
    )) {
        $sourceState[(Join-Path $sourceRoot $relative)] = `
            "canonical-$relative"
    }
    $targetState[(Join-Path $targetRoot `
        'Modules\Changed.psm1')] = 'old'
    $fileProvider = {
        param([string]$Root)
        $state = if ($Root -ieq $sourceRoot) {
            $sourceState
        }
        else {
            $targetState
        }
        return @($state.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{ FullName = [string]$_ }
        })
    }
    $hashProvider = {
        param([string]$Path)
        if ($sourceState.ContainsKey($Path)) {
            return [string]$sourceState[$Path]
        }
        return [string]$targetState[$Path]
    }
    $copyHandler = {
        param(
            [string]$SourcePath,
            [string]$DestinationPath,
            [string]$ExpectedHash
        )
        Assert-RepairSafeTreePath -Root $sourceRoot -Path $SourcePath
        Assert-RepairSafeTreePath -Root $targetRoot `
            -Path $DestinationPath
        $targetState[$DestinationPath] = $ExpectedHash
    }
    $saved = [pscustomobject]@{
        Matched = $script:MatchedCount
        Different = $script:DifferentCount
        Resolved = $script:ResolvedCount
        Remaining = $script:RemainingCount
        Failed = @($script:FailedItems)
        Unresolved = @($script:UnresolvedItems)
        Skipped = @($script:SkippedItems)
    }
    try {
        $script:MatchedCount = 0
        $script:DifferentCount = 0
        $script:ResolvedCount = 0
        $script:RemainingCount = $null
        $script:FailedItems.Clear()
        $script:UnresolvedItems.Clear()
        $script:SkippedItems.Clear()
        Sync-RepairApplicationPayload -Source $sourceRoot `
            -Target $targetRoot -Execute `
            -ApplicationFileProvider $fileProvider `
            -HashProvider $hashProvider -CopyHandler $copyHandler
        $detected = $script:DifferentCount
        if ($detected -ne 2 -or $script:ResolvedCount -ne 2) {
            throw 'Apply fixture tum farklari uygulayamadi.'
        }
        $script:MatchedCount = 0
        $script:DifferentCount = 0
        $script:ResolvedCount = 0
        $script:UnresolvedItems.Clear()
        $script:SkippedItems.Clear()
        Sync-RepairApplicationPayload -Source $sourceRoot `
            -Target $targetRoot `
            -ApplicationFileProvider $fileProvider `
            -HashProvider $hashProvider -CopyHandler $copyHandler
        $remaining = $script:DifferentCount
        $script:DifferentCount = $detected
        $script:ResolvedCount = $detected - $remaining
        $script:RemainingCount = $remaining
        if ($remaining -ne 0 -or
            (Get-RepairOutcome).Name -cne 'Success') {
            throw 'Apply sonrasi post-validation basari testi gecersiz.'
        }
    }
    finally {
        $script:MatchedCount = $saved.Matched
        $script:DifferentCount = $saved.Different
        $script:ResolvedCount = $saved.Resolved
        $script:RemainingCount = $saved.Remaining
        $script:FailedItems.Clear()
        foreach ($item in $saved.Failed) {
            $script:FailedItems.Add($item)
        }
        $script:UnresolvedItems.Clear()
        foreach ($item in $saved.Unresolved) {
            $script:UnresolvedItems.Add($item)
        }
        $script:SkippedItems.Clear()
        foreach ($item in $saved.Skipped) {
            $script:SkippedItems.Add($item)
        }
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.ApplyPostValidation'
}
function Get-RepairComfyAssets {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [switch]$IncludeAuditCatalog
    )
    $items = [Collections.Generic.List[object]]::new()
    $models = @($Config.ComfyUI.Catalog)
    if ($IncludeAuditCatalog -and
        $null -ne $Config.ComfyUI.PSObject.Properties[
            'AuditCatalog'
        ]) {
        $models += @($Config.ComfyUI.AuditCatalog)
    }
    foreach ($model in $models) {
        foreach ($asset in @($model.Assets)) {
            $items.Add([pscustomobject]@{
                Model = [string]$model.Name
                RelativePath = [string]$asset.RelativePath
                Uri = [string]$asset.Uri
                Sha256 = ([string]$asset.Sha256).ToLowerInvariant()
                SizeGB = [double]$asset.SizeGB
            })
        }
    }
    return $items.ToArray()
}
function Save-RepairDownload {
    param(
        [Parameter(Mandatory)][object]$Asset,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not $Apply) {
        return
    }
    $uri = [uri]$Asset.Uri
    if ($uri.Scheme -ne 'https') {
        throw (Get-RepairText -Key 'Repair.Error.InsecureUri' `
            -Arguments @($uri.AbsoluteUri))
    }
    $drive = [IO.DriveInfo]::new(
        [IO.Path]::GetPathRoot($Destination)
    )
    $requiredBytes = [long](
        [double]$Asset.SizeGB * 1GB * 1.1
    )
    if ($drive.AvailableFreeSpace -lt $requiredBytes) {
        throw (Get-RepairText -Key 'Repair.Error.DiskSpace' `
            -Arguments @(
                $Asset.Model,
                [math]::Ceiling($requiredBytes / 1GB),
                [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
            ))
    }
    [IO.Directory]::CreateDirectory(
        (Split-Path -Parent $Destination)
    ) | Out-Null
    $temporary = '{0}.winlama-{1}.download' -f `
        $Destination, [guid]::NewGuid().ToString('N')
    try {
        Write-RepairStatus -Level STEP -Message (Get-RepairText `
            -Key 'Repair.Download.Starting' `
            -Arguments @($Asset.Model, $Destination))
        Invoke-WebRequest -Uri $uri.AbsoluteUri `
            -OutFile $temporary -UseBasicParsing -TimeoutSec 86400
        if ((Get-RepairHash -Path $temporary) -ne $Asset.Sha256) {
            throw (Get-RepairText -Key 'Repair.Error.DownloadHashMismatch' `
                -Arguments @($Asset.Model, $Destination))
        }
        Set-RepairAtomicFile -TemporaryPath $temporary `
            -Destination $Destination
        $script:CopiedCount++
        Write-RepairLog -Event 'MODEL_DOWNLOADED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.ModelDownloaded') `
            -Data @{ Model = $Asset.Model;
                Destination = $Destination; Sha256 = $Asset.Sha256 }
        Write-RepairStatus -Level SUCCESS -Message (Get-RepairText `
            -Key 'Repair.Download.Completed' `
            -Arguments @($Asset.Model))
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
}
function Repair-ComfyUIAssets {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet(
            'PackageToInstalled', 'InstalledToPackage', 'Bidirectional'
        )]
        [string]$Direction,
        [switch]$AuditOnly
    )
    $packageModels = Join-Path $PackageRoot 'Models'
    Assert-RepairNoReparsePoint -Path $packageModels
    $installedModels = Resolve-RepairCanonicalModelPath `
        -Config $Config -Kind ComfyUI
    Assert-RepairRootsDisjoint -Source $packageModels `
        -Target $installedModels
    $assets = @(Get-RepairComfyAssets -Config $Config `
        -IncludeAuditCatalog:$AuditOnly)
    if ($AuditOnly) {
        foreach ($group in @($assets | Group-Object Model)) {
            $packageValid = $true
            $installedValid = $true
            foreach ($asset in @($group.Group)) {
                $packagePath = Resolve-RepairSafeChildPath `
                    -Root $packageModels `
                    -RelativePath $asset.RelativePath
                $installedPath = Resolve-RepairSafeChildPath `
                    -Root $installedModels `
                    -RelativePath $asset.RelativePath
                Assert-RepairSafeTreePath -Root $packageModels `
                    -Path $packagePath
                Assert-RepairSafeTreePath -Root $installedModels `
                    -Path $installedPath
                $packageValid = $packageValid -and
                    (Test-RepairFileHash -Path $packagePath `
                        -ExpectedHash $asset.Sha256)
                $installedValid = $installedValid -and
                    (Test-RepairFileHash -Path $installedPath `
                        -ExpectedHash $asset.Sha256)
            }
            if ($packageValid -and $installedValid) {
                $script:MatchedCount++
                Write-Verbose (Get-RepairText `
                    -Key 'Repair.Verbose.ModelHealthy' `
                    -Arguments @($group.Name))
                continue
            }
            $script:DifferentCount++
            $statusKey = if ($packageValid) {
                'Repair.Model.InstalledInvalid'
            }
            elseif ($installedValid) {
                'Repair.Model.PackageInvalid'
            }
            else {
                'Repair.Model.BothInvalidAudit'
            }
            $arguments = if ($statusKey -eq `
                'Repair.Model.InstalledInvalid') {
                @($group.Name, $installedModels)
            }
            elseif ($statusKey -eq 'Repair.Model.PackageInvalid') {
                @($group.Name, $packageModels)
            }
            else {
                @($group.Name)
            }
            Write-RepairStatus -Level WARN -Message (Get-RepairText `
                -Key $statusKey -Arguments $arguments)
            Write-RepairLog -Event 'MODEL_AUDIT_DIFFERENCE' `
                -Message (Get-RepairText `
                    -Key 'Repair.Log.ModelDifferenceAudited') `
                -Level WARN -Data @{
                    Model = $group.Name
                    Type = 'ComfyUI'
                    PackageValid = $packageValid
                    InstalledValid = $installedValid
                    AssetCount = $group.Count
                }
        }
        return
    }
    foreach ($asset in $assets) {
        try {
            $packagePath = Resolve-RepairSafeChildPath `
                -Root $packageModels -RelativePath $asset.RelativePath
            $installedPath = Resolve-RepairSafeChildPath `
                -Root $installedModels -RelativePath $asset.RelativePath
            Assert-RepairSafeTreePath -Root $packageModels `
                -Path $packagePath
            Assert-RepairSafeTreePath -Root $installedModels `
                -Path $installedPath
            $packageValid = Test-RepairFileHash `
                -Path $packagePath -ExpectedHash $asset.Sha256
            $installedValid = Test-RepairFileHash `
                -Path $installedPath -ExpectedHash $asset.Sha256
            if ($packageValid -and $installedValid) {
                $script:MatchedCount++
                Write-Verbose (Get-RepairText `
                    -Key 'Repair.Verbose.ModelHealthy' `
                    -Arguments @($asset.Model))
                continue
            }
            $script:DifferentCount++
            if ($Direction -eq 'PackageToInstalled') {
                if ($packageValid -and $Apply) {
                    Copy-RepairFile -Source $packagePath `
                        -Destination $installedPath `
                        -ExpectedHash $asset.Sha256
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                elseif (-not $packageValid) {
                    $message = Get-RepairText `
                        -Key 'Repair.Model.PackageInvalid' `
                        -Arguments @($asset.Model, $packagePath)
                    Write-RepairStatus -Level WARN -Message $message
                    Add-RepairUnresolved -Message $message
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($asset.Model))
                }
                continue
            }
            if ($Direction -eq 'InstalledToPackage') {
                if ($installedValid -and $Apply) {
                    Copy-RepairFile -Source $installedPath `
                        -Destination $packagePath `
                        -ExpectedHash $asset.Sha256
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                elseif (-not $installedValid) {
                    $message = Get-RepairText `
                        -Key 'Repair.Model.InstalledInvalid' `
                        -Arguments @($asset.Model, $installedPath)
                    Write-RepairStatus -Level WARN -Message $message
                    Add-RepairUnresolved -Message $message
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($asset.Model))
                }
                continue
            }
            if ($packageValid) {
                if ($Apply) {
                    Copy-RepairFile -Source $packagePath `
                        -Destination $installedPath `
                        -ExpectedHash $asset.Sha256
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($asset.Model))
                }
                continue
            }
            if ($installedValid) {
                if ($Apply) {
                    Copy-RepairFile -Source $installedPath `
                        -Destination $packagePath `
                        -ExpectedHash $asset.Sha256
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($asset.Model))
                }
                continue
            }
            Write-RepairStatus -Level WARN -Message (Get-RepairText `
                -Key 'Repair.Model.BothInvalid' `
                -Arguments @($asset.Model))
            if ($Apply) {
                Save-RepairDownload -Asset $asset `
                    -Destination $packagePath
                Copy-RepairFile -Source $packagePath `
                    -Destination $installedPath `
                    -ExpectedHash $asset.Sha256
                if (-not $WhatIfPreference) {
                    $script:ResolvedCount++
                }
            }
            else {
                Add-RepairUnresolved -Message (Get-RepairText `
                    -Key 'Repair.Unresolved.Model' `
                    -Arguments @($asset.Model))
            }
        }
        catch {
            Add-RepairFailure -Message (
                '{0}: {1}' -f $asset.Model, $_.Exception.Message
            )
            Write-RepairStatus -Level ERROR -Message (Get-RepairText `
                -Key 'Repair.Model.Failed' `
                -Arguments @($asset.Model, $_.Exception.Message))
        }
    }
}
function Get-RepairPortablePackageMetadata {
    param([Parameter(Mandatory)][string]$PackagePath)
    $metadataPath = Join-Path $PackagePath 'package.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $metadataPath -Raw `
        -Encoding UTF8 | ConvertFrom-RepairJson
}
function Test-RepairPortablePackage {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][pscustomobject]$Metadata
    )
    try {
        Assert-RepairNoReparsePoint -Path $PackagePath
        $manifest = Resolve-RepairSafeChildPath -Root $PackagePath `
            -RelativePath (Join-Path 'manifests' `
                ([string]$Metadata.ManifestRelativePath))
        Assert-RepairSafeTreePath -Root $PackagePath -Path $manifest
        if (-not (Test-RepairFileHash -Path $manifest `
            -ExpectedHash ([string]$Metadata.ManifestSha256))) {
            return $false
        }
        foreach ($blob in @($Metadata.Blobs)) {
            $path = Resolve-RepairSafeChildPath -Root $PackagePath `
                -RelativePath ([string]$blob.File)
            Assert-RepairSafeTreePath -Root $PackagePath -Path $path
            $hash = ([string]$blob.Digest).Substring(7)
            if (-not (Test-RepairFileHash -Path $path `
                -ExpectedHash $hash)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Verbose ('Tasinabilir model paketi denetlenemedi: {0} | {1}' `
            -f $PackagePath, $_.Exception.Message)
        return $false
    }
}
function Import-RepairPortableRepository {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$PackageModels
    )
    if (-not (Test-Path -LiteralPath $RepositoryRoot `
        -PathType Container)) {
        return
    }
    foreach ($metadataFile in @(Get-ChildItem `
        -LiteralPath $RepositoryRoot -Recurse -File `
        -Filter package.json -ErrorAction SilentlyContinue)) {
        try {
            $sourcePackage = $metadataFile.Directory.FullName
            $metadata = Get-RepairPortablePackageMetadata `
                -PackagePath $sourcePackage
            if ($null -eq $metadata -or
                $metadata.Format -ne 'ollama-portable-model') {
                continue
            }
            $reference = [string]$metadata.OllamaReference
            $targetPackage = `
                Get-RepairPortablePackagePathByReference `
                    -PackageModels $PackageModels `
                    -Reference $reference
            if ([string]::IsNullOrWhiteSpace($targetPackage)) {
                $relative = Get-RepairRelativePath `
                    -Root $RepositoryRoot -Path $sourcePackage
                $targetPackage = Resolve-RepairSafeChildPath `
                    -Root $PackageModels -RelativePath $relative
            }
            $sourceValid = Test-RepairPortablePackage `
                -PackagePath $sourcePackage -Metadata $metadata
            $targetValid = $false
            if (Test-Path -LiteralPath $targetPackage `
                -PathType Container) {
                $targetMetadata = Get-RepairPortablePackageMetadata `
                    -PackagePath $targetPackage
                if ($null -ne $targetMetadata) {
                    $targetValid = Test-RepairPortablePackage `
                        -PackagePath $targetPackage `
                        -Metadata $targetMetadata
                }
            }
            if ($targetValid) {
                $script:MatchedCount++
                continue
            }
            $script:DifferentCount++
            Write-RepairLog -Event 'PORTABLE_PACKAGE_DISCOVERED' `
                -Message (Get-RepairText `
                    -Key 'Repair.Log.InstalledModelDiscovered') `
                -Level $(if ($sourceValid) { 'INFO' } else { 'WARN' }) `
                -Data @{ Model = $reference;
                    Source = $sourcePackage;
                    Destination = $targetPackage;
                    SourceValid = $sourceValid }
            if (-not $Apply) {
                continue
            }
            if ($sourceValid) {
                Sync-RepairTree -Source $sourcePackage `
                    -Target $targetPackage -Mirror
            }
            else {
                $metadataHash = Get-RepairHash `
                    -Path $metadataFile.FullName
                Copy-RepairFile -Source $metadataFile.FullName `
                    -Destination (Join-Path $targetPackage `
                        'package.json') `
                    -ExpectedHash $metadataHash
            }
        }
        catch {
            Add-RepairFailure -Message (
                '{0}: {1}' -f $metadataFile.FullName,
                    $_.Exception.Message
            )
        }
    }
}
function Test-RepairInstalledOllamaModel {
    param(
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][pscustomobject]$Metadata
    )
    try {
        Assert-RepairNoReparsePoint -Path $ModelsRoot
        $manifest = Resolve-RepairSafeChildPath `
            -Root (Join-Path $ModelsRoot 'manifests') `
            -RelativePath ([string]$Metadata.ManifestRelativePath)
        Assert-RepairSafeTreePath -Root $ModelsRoot -Path $manifest
        if (-not (Test-RepairFileHash -Path $manifest `
            -ExpectedHash ([string]$Metadata.ManifestSha256))) {
            return $false
        }
        foreach ($blob in @($Metadata.Blobs)) {
            $fileName = [IO.Path]::GetFileName(
                ([string]$blob.File).Replace('/', '\')
            )
            $path = Join-Path (Join-Path $ModelsRoot 'blobs') $fileName
            Assert-RepairSafeTreePath -Root $ModelsRoot -Path $path
            $hash = ([string]$blob.Digest).Substring(7)
            if (-not (Test-RepairFileHash -Path $path `
                -ExpectedHash $hash)) {
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Verbose ('Kurulu Ollama modeli denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Invoke-RepairModelManager {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$ExportRoot,
        [Parameter(Mandatory)][string]$Action,
        [string]$ModelSelection,
        [string]$PackageSelection
    )
    $manager = Join-Path $PackageRoot 'ModelManager.ps1'
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
        throw (Get-RepairText -Key 'Repair.Error.ManagerMissing')
    }
    $copy = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $copy.Paths.Models = $ModelsRoot
    $copy.ModelTransfer.NativeModelSearchDirectories = @($ModelsRoot)
    $copy.ModelTransfer.ExportDirectory = $ExportRoot
    $copy.ModelTransfer.ImportSearchDirectories = @($ExportRoot)
    $copy.ModelTransfer.VerifyAfterImport = $false
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('Winlama-Repair-{0}' -f [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $copy.ModelTransfer.LogPath = Join-Path $temporaryRoot `
        'model-manager.log'
    $temporaryConfig = Join-Path $temporaryRoot 'config.json'
    try {
        [IO.File]::WriteAllText(
            $temporaryConfig,
            ($copy | ConvertTo-Json -Depth 100),
            [Text.UTF8Encoding]::new($false)
        )
        $arguments = @(
            '-ConfigPath', $temporaryConfig,
            '-Action', $Action,
            '-NoPause'
        )
        if (-not [string]::IsNullOrWhiteSpace($ModelSelection)) {
            $arguments += @('-ModelSelection', $ModelSelection)
        }
        if (-not [string]::IsNullOrWhiteSpace($PackageSelection)) {
            $arguments += @('-PackageSelection', $PackageSelection)
        }
        if ($VerbosePreference -ne 'SilentlyContinue') {
            $arguments += '-Verbose'
        }
        $powerShellPath = (Get-Process -Id $PID `
            -ErrorAction Stop).Path
        Write-RepairLog -Event 'MODEL_MANAGER_STARTED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.ModelTransferStarted') `
            -Data @{ Action = $Action;
                ModelSelection = $ModelSelection;
                PackageSelection = $PackageSelection;
                ModelsRoot = $ModelsRoot; ExportRoot = $ExportRoot }
        $managerArguments = @(
            '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', $manager
        ) + $arguments
        $managerExitCode = Invoke-RepairBoundedChildProcess `
            -FilePath $powerShellPath `
            -Arguments $managerArguments `
            -WorkingDirectory $PackageRoot `
            -TimeoutSeconds ([int]$Config.Network.DownloadTimeoutSeconds)
        if ($managerExitCode -ne 0) {
            throw (Get-RepairText -Key 'Repair.Error.ManagerFailed' `
                -Arguments @($Action, $managerExitCode))
        }
        Write-RepairLog -Event 'MODEL_MANAGER_COMPLETED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.ModelTransferCompleted') `
            -Data @{ Action = $Action;
                ModelSelection = $ModelSelection;
                PackageSelection = $PackageSelection }
    }
    finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
function Get-RepairOllamaExecutable {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$PathExists = {
            param([string]$Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        },
        [scriptblock]$ReparseAsserter = {
            param([string]$Path)
            Assert-RepairNoReparsePoint -Path $Path
        }
    )
    $installPath = Resolve-RepairPath `
        -Path ([string]$Config.Ollama.InstallPath)
    $candidate = [IO.Path]::GetFullPath(
        (Join-Path $installPath 'ollama.exe')
    )
    if ([bool](& $PathExists $candidate)) {
        & $ReparseAsserter $installPath
        & $ReparseAsserter $candidate
        return $candidate
    }
    throw (Get-RepairText -Key 'Repair.Error.OllamaMissing')
}
function Get-RepairOllamaApplicationExecutable {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [scriptblock]$PathExists = {
            param([string]$Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        }
    )
    $resolvedCli = [IO.Path]::GetFullPath($CliPath)
    $application = Join-Path (Split-Path -Parent $resolvedCli) `
        'ollama app.exe'
    if ([bool](& $PathExists $application)) {
        return [IO.Path]::GetFullPath($application)
    }
    throw (Get-RepairText `
        -Key 'Ollama.Error.ApplicationExecutableMissing')
}
function Get-RepairOllamaApplicationArgumentList {
    return @('--hide', '--fast-startup')
}
function New-RepairOllamaApplicationStartParameters {
    param([Parameter(Mandatory)][string]$ApplicationPath)
    $resolvedApplication = [IO.Path]::GetFullPath($ApplicationPath)
    return @{
        FilePath = $resolvedApplication
        ArgumentList = @(Get-RepairOllamaApplicationArgumentList)
        WorkingDirectory = Split-Path -Parent $resolvedApplication
        PassThru = $true
    }
}
function Get-RepairOllamaDownloadMutexName {
    param([Parameter(Mandatory)][string]$CliPath)
    $identity = [IO.Path]::GetFullPath($CliPath).ToUpperInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($identity)
        )
    }
    finally {
        $sha256.Dispose()
    }
    $suffix = [BitConverter]::ToString($hash).Replace('-', '')
    return 'Global\Winlama.Repair.OllamaDownload.{0}' -f `
        $suffix.Substring(0, 32)
}
function Enter-RepairOllamaDownloadMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900,
        [scriptblock]$MutexFactory = {
            param([string]$MutexName)
            [Threading.Mutex]::new($false, $MutexName)
        }
    )
    $mutex = & $MutexFactory $Name
    if ($null -eq $mutex) {
        throw 'Ollama indirme mutex nesnesi olusturulamadi.'
    }
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(
                [TimeSpan]::FromSeconds($TimeoutSeconds)
            )
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Verbose 'Terk edilmis Ollama indirme mutexi devralindi.'
        }
        if (-not $acquired) {
            throw 'Baska bir Ollama paket indirmesi halen calisiyor.'
        }
        return ,$mutex
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}
function Exit-RepairOllamaDownloadMutex {
    param([Parameter(Mandatory)][object]$Mutex)
    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}
function Get-RepairOllamaManagedExecutablePaths {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$ApplicationPath,
        [scriptblock]$FileProvider
    )
    $cli = [IO.Path]::GetFullPath($CliPath)
    $application = [IO.Path]::GetFullPath($ApplicationPath)
    $root = Split-Path -Parent $application
    $cliRoot = Split-Path -Parent $cli
    if (-not $cliRoot.Equals(
        $root,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Ollama CLI ve tray uygulamasi ayni dizinde degil.'
    }
    $paths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $null = $paths.Add($cli)
    $null = $paths.Add($application)
    $files = if ($null -eq $FileProvider) {
        @(Get-RepairSafeTreeFiles -Root $root)
    }
    else {
        @(& $FileProvider $root)
    }
    foreach ($file in $files) {
        $path = if ($file -is [string]) {
            [string]$file
        }
        else {
            [string]$file.FullName
        }
        if ([string]::IsNullOrWhiteSpace($path) -or
            [IO.Path]::GetFileName($path) -ine `
                'ollama_llama_server.exe') {
            continue
        }
        $resolved = [IO.Path]::GetFullPath($path)
        if (-not (Test-RepairPathWithinRoot `
            -Root $root -Path $resolved)) {
            throw 'Ollama server calistirilabilir yolu guvenli degil.'
        }
        $null = $paths.Add($resolved)
    }
    return @($paths)
}
function Get-RepairManagedOllamaProcesses {
    param(
        [Parameter(Mandatory)][string[]]$ExecutablePaths,
        [scriptblock]$ProcessProvider = {
            Get-CimInstance -ClassName Win32_Process `
                -ErrorAction Stop
        }
    )
    $paths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $ExecutablePaths) {
        $null = $paths.Add([IO.Path]::GetFullPath($path))
    }
    $processIds = [Collections.Generic.HashSet[int]]::new()
    $processes = [Collections.Generic.List[object]]::new()
    foreach ($processInfo in @(& $ProcessProvider)) {
        $pathProperty = `
            $processInfo.PSObject.Properties['ExecutablePath']
        $idProperty = $processInfo.PSObject.Properties['ProcessId']
        if ($null -eq $pathProperty -or $null -eq $idProperty -or
            [string]::IsNullOrWhiteSpace(
                [string]$pathProperty.Value
            )) {
            continue
        }
        try {
            $resolved = [IO.Path]::GetFullPath(
                [string]$pathProperty.Value
            )
        }
        catch {
            Write-Verbose ('Ollama surec yolu okunamadi: {0}' -f `
                $_.Exception.Message)
            continue
        }
        if ($paths.Contains($resolved)) {
            $processId = [int]$idProperty.Value
            if ($processIds.Add($processId)) {
                $processes.Add([pscustomobject]@{
                    ProcessId = $processId
                    ExecutablePath = $resolved
                })
            }
        }
    }
    return $processes.ToArray()
}
function Get-RepairManagedOllamaProcessIds {
    param(
        [Parameter(Mandatory)][string[]]$ExecutablePaths,
        [scriptblock]$ProcessProvider
    )
    $parameters = @{ ExecutablePaths = $ExecutablePaths }
    if ($null -ne $ProcessProvider) {
        $parameters.ProcessProvider = $ProcessProvider
    }
    return @(
        Get-RepairManagedOllamaProcesses @parameters |
            ForEach-Object { [int]$_.ProcessId }
    )
}
function Stop-RepairManagedOllamaProcesses {
    param(
        [Parameter(Mandatory)][string[]]$ExecutablePaths,
        [int[]]$PreservedProcessIds = @(),
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [scriptblock]$ProcessProvider,
        [scriptblock]$ProcessStopper = {
            param([int]$ProcessId)
            Stop-Process -Id $ProcessId -Force `
                -ErrorAction SilentlyContinue
        },
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [scriptblock]$Delay = {
            param([int]$Milliseconds)
            Start-Sleep -Milliseconds $Milliseconds
        }
    )
    $existing = [Collections.Generic.HashSet[int]]::new()
    foreach ($processId in $PreservedProcessIds) {
        $null = $existing.Add($processId)
    }
    $deadline = (& $Clock).AddSeconds($TimeoutSeconds)
    $emptyPasses = 0
    do {
        $parameters = @{ ExecutablePaths = $ExecutablePaths }
        if ($null -ne $ProcessProvider) {
            $parameters.ProcessProvider = $ProcessProvider
        }
        $newProcessIds = @(
            Get-RepairManagedOllamaProcessIds @parameters |
                Where-Object { -not $existing.Contains([int]$_) } |
                Sort-Object -Unique
        )
        if ($newProcessIds.Count -eq 0) {
            $emptyPasses++
            if ($emptyPasses -ge 3) {
                return
            }
        }
        else {
            $emptyPasses = 0
            foreach ($processId in $newProcessIds) {
                $null = & $ProcessStopper ([int]$processId)
            }
        }
        $null = & $Delay 200
    } while ((& $Clock) -lt $deadline)
    $parameters = @{ ExecutablePaths = $ExecutablePaths }
    if ($null -ne $ProcessProvider) {
        $parameters.ProcessProvider = $ProcessProvider
    }
    $remaining = @(
        Get-RepairManagedOllamaProcessIds @parameters |
            Where-Object { -not $existing.Contains([int]$_) }
    )
    if ($remaining.Count -gt 0) {
        throw ('Ollama surecleri kapatilamadi: {0}' -f `
            ($remaining -join ', '))
    }
}
function Wait-RepairOllamaApi {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1, 900)][int]$TimeoutSeconds = 90,
        [scriptblock]$Probe = {
            param([uri]$Endpoint)
            $null = Invoke-RestMethod -Uri $Endpoint -TimeoutSec 2
        },
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [scriptblock]$Delay = {
            param([int]$Milliseconds)
            Start-Sleep -Milliseconds $Milliseconds
        }
    )
    $deadline = (& $Clock).AddSeconds($TimeoutSeconds)
    do {
        try {
            $null = & $Probe $Uri
            return $true
        }
        catch {
            Write-Verbose ('Gecici Ollama API denetimi basarisiz: {0}' `
                -f $_.Exception.Message)
        }
        if ((& $Clock) -ge $deadline) {
            return $false
        }
        $null = & $Delay 1000
    } while ((& $Clock) -lt $deadline)
    return $false
}
function Get-RepairOllamaApiUri {
    param(
        [AllowEmptyString()][string]$HostValue = '',
        [ValidateRange(1, 65535)][int]$DefaultPort = 11434
    )
    if ([string]::IsNullOrWhiteSpace($HostValue)) {
        return [uri](
            'http://127.0.0.1:{0}/api/version' -f $DefaultPort
        )
    }
    $candidate = $HostValue.Trim().TrimEnd('/')
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $candidate = 'http://' + $candidate
    }
    $parsed = $null
    if (-not [uri]::TryCreate(
            $candidate,
            [UriKind]::Absolute,
            [ref]$parsed
        ) -or $parsed.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($parsed.Host)) {
        throw "OLLAMA_HOST gecersiz: $HostValue"
    }
    $builder = [UriBuilder]::new($parsed)
    $parsedAddress = $null
    $addressText = $builder.Host.Trim('[', ']')
    if ([Net.IPAddress]::TryParse(
            $addressText,
            [ref]$parsedAddress
        )) {
        if ($parsedAddress.Equals([Net.IPAddress]::Any)) {
            $builder.Host = '127.0.0.1'
        }
        elseif ($parsedAddress.Equals([Net.IPAddress]::IPv6Any)) {
            $builder.Host = '::1'
        }
    }
    $builder.Path = 'api/version'
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}
function Wait-RepairOllamaTrayReady {
    param(
        [Parameter(Mandatory)][string]$ApplicationPath,
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1, 900)][int]$TimeoutSeconds = 120,
        [scriptblock]$ProcessProvider,
        [scriptblock]$Probe = {
            param([uri]$Endpoint)
            $null = Invoke-RestMethod -Uri $Endpoint -TimeoutSec 2
        },
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [scriptblock]$Delay = {
            param([int]$Milliseconds)
            Start-Sleep -Milliseconds $Milliseconds
        }
    )
    $application = [IO.Path]::GetFullPath($ApplicationPath)
    $deadline = (& $Clock).AddSeconds($TimeoutSeconds)
    do {
        $parameters = @{ ExecutablePaths = @($application) }
        if ($null -ne $ProcessProvider) {
            $parameters.ProcessProvider = $ProcessProvider
        }
        $trayProcesses = @(
            Get-RepairManagedOllamaProcesses @parameters
        )
        if ($trayProcesses.Count -gt 0) {
            try {
                $null = & $Probe $Uri
                return $true
            }
            catch {
                Write-Verbose ('Normal Ollama API denetimi basarisiz: {0}' `
                    -f $_.Exception.Message)
            }
        }
        if ((& $Clock) -ge $deadline) {
            return $false
        }
        $null = & $Delay 1000
    } while ((& $Clock) -lt $deadline)
    return $false
}
function Get-RepairOllamaDownloadFailure {
    param(
        [AllowNull()]
        [Management.Automation.ErrorRecord]$OperationError,
        [AllowNull()]
        [Management.Automation.ErrorRecord]$CleanupError
    )
    if ($null -ne $OperationError) {
        if ($null -ne $CleanupError) {
            try {
                $OperationError.Exception.Data[
                    'Repair.OllamaCleanupError'
                ] = $CleanupError.Exception.Message
            }
            catch {
                Write-Verbose ('Temizleme hatasi ana hataya eklenemedi: {0}' `
                    -f $_.Exception.Message)
            }
        }
        return $OperationError
    }
    return $CleanupError
}
function Invoke-RepairOllamaPackageDownload {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Reference
    )
    $ollama = Get-RepairOllamaExecutable -Config $Config
    $application = Get-RepairOllamaApplicationExecutable `
        -CliPath $ollama
    $mutexName = Get-RepairOllamaDownloadMutexName `
        -CliPath $ollama
    $oldHost = [Environment]::GetEnvironmentVariable(
        'OLLAMA_HOST', 'Process'
    )
    $oldModels = [Environment]::GetEnvironmentVariable(
        'OLLAMA_MODELS', 'Process'
    )
    $mutex = $null
    $managedProcessPaths = @($ollama, $application)
    $store = $null
    $process = $null
    $processIsolationAttempted = $false
    $environmentChanged = $false
    $preexistingTray = $false
    $isolatedBaselineProcessIds = @()
    $operationError = $null
    try {
        $mutex = Enter-RepairOllamaDownloadMutex -Name $mutexName
        $managedProcessPaths = @(
            Get-RepairOllamaManagedExecutablePaths `
                -CliPath $ollama -ApplicationPath $application
        )
        $preexistingProcesses = @(
            Get-RepairManagedOllamaProcesses `
                -ExecutablePaths $managedProcessPaths
        )
        $preexistingTray = @($preexistingProcesses | Where-Object {
            ([string]$_.ExecutablePath).Equals(
                $application,
                [StringComparison]::OrdinalIgnoreCase
            )
        }).Count -gt 0
        $processIsolationAttempted = $true
        Stop-RepairManagedOllamaProcesses `
            -ExecutablePaths $managedProcessPaths
        $isolatedBaselineProcessIds = @(
            Get-RepairManagedOllamaProcessIds `
                -ExecutablePaths $managedProcessPaths
        )
        if ($isolatedBaselineProcessIds.Count -gt 0) {
            throw 'Ollama surec izolasyonu tamamlanamadi.'
        }
        $store = Join-Path (Join-Path $PackageRoot 'Models') `
            ('.repair-{0}' -f [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($store) | Out-Null
        $listener = [Net.Sockets.TcpListener]::new(
            [Net.IPAddress]::Loopback,
            0
        )
        try {
            $listener.Start()
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        }
        finally {
            $listener.Stop()
        }
        $environmentChanged = $true
        $env:OLLAMA_HOST = "127.0.0.1:$port"
        $env:OLLAMA_MODELS = $store
        $raceProcessIds = @(
            Get-RepairManagedOllamaProcessIds `
                -ExecutablePaths $managedProcessPaths
        )
        if ($raceProcessIds.Count -gt 0) {
            throw 'Ollama surec izolasyonu baslatma oncesi bozuldu.'
        }
        $startParameters = New-RepairOllamaApplicationStartParameters `
            -ApplicationPath $application
        $process = Start-Process @startParameters
        if (-not (Wait-RepairOllamaApi `
            -Uri "http://127.0.0.1:$port/api/version" `
            -TimeoutSeconds 90)) {
            throw (Get-RepairText -Key 'Repair.Error.OllamaTimeout')
        }
        Write-RepairStatus -Level STEP -Message (Get-RepairText `
            -Key 'Repair.Ollama.DownloadStarting' `
            -Arguments @($Reference))
        $pullExitCode = Invoke-RepairBoundedChildProcess `
            -FilePath $ollama -Arguments @('pull', $Reference) `
            -WorkingDirectory (Split-Path -Parent $ollama) `
            -TimeoutSeconds ([int]$Config.Network.DownloadTimeoutSeconds)
        if ($pullExitCode -ne 0) {
            throw (Get-RepairText -Key 'Repair.Error.OllamaPullFailed' `
                -Arguments @($Reference, $pullExitCode))
        }
        Invoke-RepairModelManager -PackageRoot $PackageRoot `
            -Config $Config -ModelsRoot $store `
            -ExportRoot (Join-Path $PackageRoot 'Models') `
            -Action Export -ModelSelection $Reference
    }
    catch {
        $operationError = $_
    }
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    if ($processIsolationAttempted) {
        try {
            $managedProcessPaths = @(
                Get-RepairOllamaManagedExecutablePaths `
                    -CliPath $ollama -ApplicationPath $application
            )
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
        try {
            Stop-RepairManagedOllamaProcesses `
                -ExecutablePaths $managedProcessPaths `
                -PreservedProcessIds $isolatedBaselineProcessIds
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force `
                    -ErrorAction SilentlyContinue
            }
            $process.Dispose()
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    $managedProcessesEmpty = -not $processIsolationAttempted
    if ($processIsolationAttempted) {
        try {
            $remainingProcessIds = @(
                Get-RepairManagedOllamaProcessIds `
                    -ExecutablePaths $managedProcessPaths
            )
            if ($remainingProcessIds.Count -gt 0) {
                throw ('Izole Ollama surecleri halen calisiyor: {0}' -f `
                    ($remainingProcessIds -join ', '))
            }
            $managedProcessesEmpty = $true
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    $hostRestored = -not $environmentChanged
    $modelsRestored = -not $environmentChanged
    if ($environmentChanged) {
        try {
            [Environment]::SetEnvironmentVariable(
                'OLLAMA_HOST', $oldHost, 'Process'
            )
            $hostRestored = $true
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
        try {
            [Environment]::SetEnvironmentVariable(
                'OLLAMA_MODELS', $oldModels, 'Process'
            )
            $modelsRestored = $true
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($store) -and
            (Test-Path -LiteralPath $store)) {
            Remove-Item -LiteralPath $store -Recurse -Force `
                -ErrorAction Stop
        }
    }
    catch {
        $cleanupFailures.Add($_.Exception)
    }
    if ($preexistingTray -and $managedProcessesEmpty -and
        $hostRestored -and $modelsRestored) {
        $restartProcess = $null
        try {
            $restartParameters = `
                New-RepairOllamaApplicationStartParameters `
                    -ApplicationPath $application
            $restartProcess = Start-Process @restartParameters
            $normalApiUri = Get-RepairOllamaApiUri `
                -HostValue $oldHost `
                -DefaultPort ([int]$Config.Ollama.Port)
            if (-not (Wait-RepairOllamaTrayReady `
                -ApplicationPath $application -Uri $normalApiUri `
                -TimeoutSeconds 120)) {
                throw 'Ollama tray veya normal API geri baslatilamadi.'
            }
        }
        catch {
            $cleanupFailures.Add($_.Exception)
            try {
                Stop-RepairManagedOllamaProcesses `
                    -ExecutablePaths $managedProcessPaths
            }
            catch {
                $cleanupFailures.Add($_.Exception)
            }
        }
        finally {
            if ($null -ne $restartProcess) {
                $restartProcess.Dispose()
            }
        }
    }
    if ($null -ne $mutex) {
        try {
            Exit-RepairOllamaDownloadMutex -Mutex $mutex
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
    }
    $cleanupError = $null
    if ($cleanupFailures.Count -gt 0) {
        foreach ($cleanupFailure in $cleanupFailures) {
            Write-Verbose ('Ollama temizleme ek hatasi: {0}' -f `
                $cleanupFailure.Message)
        }
        $cleanupException = if ($cleanupFailures.Count -eq 1) {
            $cleanupFailures[0]
        }
        else {
            [AggregateException]::new(
                'Birden fazla Ollama temizleme hatasi olustu.',
                [Exception[]]$cleanupFailures.ToArray()
            )
        }
        $cleanupError = [Management.Automation.ErrorRecord]::new(
            $cleanupException,
            'RepairOllamaCleanupFailed',
            [Management.Automation.ErrorCategory]::CloseError,
            $application
        )
    }
    if ($null -ne $operationError -and $null -ne $cleanupError) {
        Write-Verbose ('Ollama temizleme ek hatasi: {0}' -f `
            $cleanupError.Exception.Message)
    }
    $failure = Get-RepairOllamaDownloadFailure `
        -OperationError $operationError -CleanupError $cleanupError
    if ($null -ne $failure) {
        throw $failure
    }
}
function Assert-RepairOllamaApplicationContract {
    $root = [IO.Path]::GetFullPath('C:\Fixture\Ollama')
    $cli = Join-Path $root 'ollama.exe'
    $expected = Join-Path $root 'ollama app.exe'
    $executableConfig = [pscustomobject]@{
        Ollama = [pscustomobject]@{ InstallPath = $root }
    }
    $reparseChecks = [Collections.Generic.List[string]]::new()
    $configuredExecutable = Get-RepairOllamaExecutable `
        -Config $executableConfig -PathExists ({
            param([string]$Path)
            return $Path -ieq $cli
        }.GetNewClosure()) -ReparseAsserter ({
            param([string]$Path)
            $null = $reparseChecks.Add($Path)
        }.GetNewClosure())
    $foreignPathRejected = $false
    try {
        $null = Get-RepairOllamaExecutable `
            -Config $executableConfig `
            -PathExists { param([string]$Path) $false }
    }
    catch {
        $foreignPathRejected = $true
    }
    $reparseRejected = $false
    try {
        $null = Get-RepairOllamaExecutable `
            -Config $executableConfig `
            -PathExists { param([string]$Path) $true } `
            -ReparseAsserter { throw 'fixture reparse' }
    }
    catch {
        $reparseRejected = $true
    }
    $executableSource = (Get-Command Get-RepairOllamaExecutable `
        -ErrorAction Stop).Definition
    $pathTester = {
        param([string]$Path)
        return [IO.Path]::GetFullPath($Path).Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        )
    }.GetNewClosure()
    $application = Get-RepairOllamaApplicationExecutable `
        -CliPath $cli -PathExists $pathTester
    $parameters = New-RepairOllamaApplicationStartParameters `
        -ApplicationPath $application
    $server = Join-Path $root `
        'lib\runners\cpu\ollama_llama_server.exe'
    $managedPaths = @(
        Get-RepairOllamaManagedExecutablePaths `
            -CliPath $cli -ApplicationPath $application `
            -FileProvider {
                param([string]$Path)
                [pscustomobject]@{ FullName = $server }
            }.GetNewClosure()
    )
    $unrelated = [IO.Path]::GetFullPath(
        'C:\Fixture\Other\ollama_llama_server.exe'
    )
    $preexisting = @(
        [pscustomobject]@{
            ProcessId = 11; ExecutablePath = $application
        },
        [pscustomobject]@{ ProcessId = 12; ExecutablePath = $cli },
        [pscustomobject]@{ ProcessId = 13; ExecutablePath = $server },
        [pscustomobject]@{ ProcessId = 31; ExecutablePath = $unrelated }
    )
    $preexistingSnapshot = @(
        Get-RepairManagedOllamaProcesses `
            -ExecutablePaths $managedPaths `
            -ProcessProvider { $preexisting }.GetNewClosure()
    )
    $preexistingTrayDetected = @($preexistingSnapshot | Where-Object {
        ([string]$_.ExecutablePath).Equals(
            $application,
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count -eq 1
    $existingIds = @(
        $preexistingSnapshot | ForEach-Object { [int]$_.ProcessId }
    )
    $preStopped = [Collections.Generic.HashSet[int]]::new()
    $preStopProvider = {
        @($preexisting | Where-Object {
            -not $preStopped.Contains([int]$_.ProcessId)
        })
    }.GetNewClosure()
    $preStopper = {
        param([int]$ProcessId)
        $null = $preStopped.Add($ProcessId)
    }.GetNewClosure()
    Stop-RepairManagedOllamaProcesses `
        -ExecutablePaths $managedPaths `
        -ProcessProvider $preStopProvider `
        -ProcessStopper $preStopper -Delay { param($Value) }
    $runningProcesses = @(
        $preexisting +
        [pscustomobject]@{
            ProcessId = 21; ExecutablePath = $application
        },
        [pscustomobject]@{ ProcessId = 22; ExecutablePath = $cli },
        [pscustomobject]@{ ProcessId = 23; ExecutablePath = $server }
    )
    $isolatedStopped = [Collections.Generic.HashSet[int]]::new()
    $processProvider = {
        @($runningProcesses | Where-Object {
            -not $isolatedStopped.Contains([int]$_.ProcessId)
        })
    }.GetNewClosure()
    $processStopper = {
        param([int]$ProcessId)
        $null = $isolatedStopped.Add($ProcessId)
    }.GetNewClosure()
    Stop-RepairManagedOllamaProcesses `
        -ExecutablePaths $managedPaths `
        -PreservedProcessIds $existingIds `
        -ProcessProvider $processProvider `
        -ProcessStopper $processStopper -Delay { param($Value) }
    $mutexName = Get-RepairOllamaDownloadMutexName -CliPath $cli
    $otherMutexName = Get-RepairOllamaDownloadMutexName `
        -CliPath 'C:\Fixture\OtherOllama\ollama.exe'
    $fakeMutex = [pscustomobject]@{
        WaitCount = 0
        Released = $false
        Disposed = $false
    }
    $fakeMutex | Add-Member -MemberType ScriptMethod `
        -Name WaitOne -Value {
            param([TimeSpan]$Timeout)
            $this.WaitCount++
            return $true
        }
    $fakeMutex | Add-Member -MemberType ScriptMethod `
        -Name ReleaseMutex -Value { $this.Released = $true }
    $fakeMutex | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    $enteredMutex = Enter-RepairOllamaDownloadMutex `
        -Name $mutexName -TimeoutSeconds 1 `
        -MutexFactory { param($Name) $fakeMutex }.GetNewClosure()
    Exit-RepairOllamaDownloadMutex -Mutex $enteredMutex
    $timeoutMutex = [pscustomobject]@{ Disposed = $false }
    $timeoutMutex | Add-Member -MemberType ScriptMethod `
        -Name WaitOne -Value {
            param([TimeSpan]$Timeout)
            return $false
        }
    $timeoutMutex | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    $mutexTimeoutRejected = $false
    try {
        $null = Enter-RepairOllamaDownloadMutex `
            -Name $mutexName -TimeoutSeconds 1 `
            -MutexFactory {
                param($Name)
                $timeoutMutex
            }.GetNewClosure()
    }
    catch {
        $mutexTimeoutRejected = $true
    }
    $lateState = [pscustomobject]@{
        Now = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    }
    $lateReady = Wait-RepairOllamaApi `
        -Uri 'http://127.0.0.1:54321/api/version' `
        -TimeoutSeconds 1 -Probe {
            param([uri]$Endpoint)
            $lateState.Now = $lateState.Now.AddSeconds(2)
        }.GetNewClosure() `
        -Clock { $lateState.Now }.GetNewClosure() `
        -Delay { param($Value) }
    $timeoutState = [pscustomobject]@{
        Now = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    }
    $timeoutAccepted = Wait-RepairOllamaApi `
        -Uri 'http://127.0.0.1:54321/api/version' `
        -TimeoutSeconds 1 -Probe {
            param([uri]$Endpoint)
            $timeoutState.Now = $timeoutState.Now.AddSeconds(2)
            throw 'fixture timeout'
        }.GetNewClosure() `
        -Clock { $timeoutState.Now }.GetNewClosure() `
        -Delay { param($Value) }
    $trayReadyState = [pscustomobject]@{
        Now = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    }
    $trayReady = Wait-RepairOllamaTrayReady `
        -ApplicationPath $application `
        -Uri 'http://127.0.0.1:11434/api/version' `
        -TimeoutSeconds 1 -ProcessProvider {
            [pscustomobject]@{
                ProcessId = 41
                ExecutablePath = $application
            }
        }.GetNewClosure() -Probe {
            param([uri]$Endpoint)
            $trayReadyState.Now = $trayReadyState.Now.AddSeconds(2)
        }.GetNewClosure() `
        -Clock { $trayReadyState.Now }.GetNewClosure() `
        -Delay { param($Value) }
    $trayMissingState = [pscustomobject]@{
        Now = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    }
    $missingTrayAccepted = Wait-RepairOllamaTrayReady `
        -ApplicationPath $application `
        -Uri 'http://127.0.0.1:11434/api/version' `
        -TimeoutSeconds 1 -ProcessProvider {
            $trayMissingState.Now = `
                $trayMissingState.Now.AddSeconds(2)
            return @()
        }.GetNewClosure() -Probe { param([uri]$Endpoint) } `
        -Clock { $trayMissingState.Now }.GetNewClosure() `
        -Delay { param($Value) }
    $customHostUri = Get-RepairOllamaApiUri `
        -HostValue 'localhost:22445' -DefaultPort 11434
    $defaultHostUri = Get-RepairOllamaApiUri `
        -HostValue '' -DefaultPort 11435
    $wildcardHostUri = Get-RepairOllamaApiUri `
        -HostValue 'http://0.0.0.0:33445' -DefaultPort 11434
    $wildcardIpv6HostUri = Get-RepairOllamaApiUri `
        -HostValue 'http://[::]:33446' -DefaultPort 11434
    $boundedProcess = [pscustomobject]@{
        Id = 4242
        ExitCode = 0
        WaitCalls = 0
        Disposed = $false
    }
    $boundedProcess | Add-Member -MemberType ScriptMethod `
        -Name Start -Value { return $true }
    $boundedProcess | Add-Member -MemberType ScriptMethod `
        -Name WaitForExit -Value {
            param([int]$Milliseconds)
            $this.WaitCalls++
            return $this.WaitCalls -gt 1
        }
    $boundedProcess | Add-Member -MemberType ScriptMethod `
        -Name Dispose -Value { $this.Disposed = $true }
    $treeTerminated = [pscustomobject]@{ Value = $false }
    $boundedFactory = {
        param($StartInfo)
        $boundedProcess
    }.GetNewClosure()
    $boundedTerminator = {
        param($ChildProcess)
        $treeTerminated.Value = $true
    }.GetNewClosure()
    $boundedTimeoutRejected = $false
    try {
        $null = Invoke-RepairBoundedChildProcess `
            -FilePath $cli -Arguments @('pull', 'fixture:latest') `
            -WorkingDirectory $root -TimeoutSeconds 1 `
            -ProcessFactory $boundedFactory `
            -TreeTerminator $boundedTerminator
    }
    catch [TimeoutException] {
        $boundedTimeoutRejected = $true
    }
    $taskkillTimeoutRejected = $false
    try {
        Assert-RepairTaskkillOutcome -Completed $false `
            -ExitCode 0 -RootExitedBeforeTaskkill $false
    }
    catch [TimeoutException] {
        $taskkillTimeoutRejected = $true
    }
    $taskkillNonzeroRejected = $false
    try {
        Assert-RepairTaskkillOutcome -Completed $true `
            -ExitCode 5 -RootExitedBeforeTaskkill $false
    }
    catch [InvalidOperationException] {
        $taskkillNonzeroRejected = $true
    }
    $taskkillExitedRaceAccepted = $true
    try {
        Assert-RepairTaskkillOutcome -Completed $true `
            -ExitCode 128 -RootExitedBeforeTaskkill $true
    }
    catch {
        $taskkillExitedRaceAccepted = $false
    }
    $primaryError = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('fixture primary'),
        'RepairFixturePrimary',
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
    $cleanupError = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('fixture cleanup'),
        'RepairFixtureCleanup',
        [Management.Automation.ErrorCategory]::CloseError,
        $null
    )
    $selectedPrimary = Get-RepairOllamaDownloadFailure `
        -OperationError $primaryError -CleanupError $cleanupError
    $selectedCleanup = Get-RepairOllamaDownloadFailure `
        -OperationError $null -CleanupError $cleanupError
    $missingRejected = $false
    try {
        $null = Get-RepairOllamaApplicationExecutable `
            -CliPath $cli -PathExists { param($Path) $false }
    }
    catch {
        $missingRejected = $true
    }
    $source = (Get-Command Invoke-RepairOllamaPackageDownload `
        -ErrorAction Stop).Definition
    $forbiddenCommand = 'ser' + 've'
    $forbiddenPattern = '(?i)(?:^|\W){0}(?:\W|$)' -f `
        [regex]::Escape($forbiddenCommand)
    $mutexIndex = $source.IndexOf(
        'Enter-RepairOllamaDownloadMutex',
        [StringComparison]::Ordinal
    )
    $snapshotIndex = $source.IndexOf(
        'Get-RepairManagedOllamaProcesses',
        [StringComparison]::Ordinal
    )
    $preStopIndex = $source.IndexOf(
        'Stop-RepairManagedOllamaProcesses',
        [StringComparison]::Ordinal
    )
    $baselineIndex = $source.IndexOf(
        'Get-RepairManagedOllamaProcessIds',
        $preStopIndex,
        [StringComparison]::Ordinal
    )
    $environmentIndex = $source.IndexOf(
        '$env:OLLAMA_HOST =',
        [StringComparison]::Ordinal
    )
    $raceIndex = $source.IndexOf(
        '$raceProcessIds = @(',
        [StringComparison]::Ordinal
    )
    $startIndex = $source.IndexOf(
        'Start-Process @startParameters',
        [StringComparison]::Ordinal
    )
    $cleanupIndex = $source.IndexOf(
        'Stop-RepairManagedOllamaProcesses',
        $startIndex,
        [StringComparison]::Ordinal
    )
    $emptyCheckIndex = $source.IndexOf(
        '$remainingProcessIds = @(',
        $cleanupIndex,
        [StringComparison]::Ordinal
    )
    $restoreIndex = $source.IndexOf(
        "'OLLAMA_HOST', `$oldHost",
        [StringComparison]::Ordinal
    )
    $removeIndex = $source.IndexOf(
        'Remove-Item -LiteralPath $store',
        [StringComparison]::Ordinal
    )
    $restartIndex = $source.IndexOf(
        'Start-Process @restartParameters',
        [StringComparison]::Ordinal
    )
    $trayWaitIndex = $source.IndexOf(
        'Wait-RepairOllamaTrayReady',
        $restartIndex,
        [StringComparison]::Ordinal
    )
    $releaseIndex = $source.IndexOf(
        'Exit-RepairOllamaDownloadMutex',
        [StringComparison]::Ordinal
    )
    $failureIndex = $source.IndexOf(
        'Get-RepairOllamaDownloadFailure',
        [StringComparison]::Ordinal
    )
    if (-not $configuredExecutable.Equals(
            $cli,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $reparseChecks.Count -ne 2 -or
        -not $foreignPathRejected -or -not $reparseRejected -or
        $executableSource -match 'Get-Command\s+ollama' -or
        -not $application.Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        ([string[]]$parameters.ArgumentList -join '|') -cne `
            '--hide|--fast-startup' -or
        -not ([string]$parameters.WorkingDirectory).Equals(
            $root,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not [bool]$parameters.PassThru -or
        $managedPaths.Count -ne 3 -or
        $server -notin $managedPaths -or
        (@($existingIds | Sort-Object) -join '|') -cne `
            '11|12|13' -or
        -not $preexistingTrayDetected -or
        -not $preStopped.SetEquals([int[]]@(11, 12, 13)) -or
        -not $isolatedStopped.SetEquals([int[]]@(21, 22, 23)) -or
        $preStopped.Contains(31) -or $isolatedStopped.Contains(31) -or
        -not $mutexName.StartsWith(
            'Global\Winlama.Repair.OllamaDownload.',
            [StringComparison]::Ordinal
        ) -or $mutexName -ceq $otherMutexName -or
        $mutexName -cne (Get-RepairOllamaDownloadMutexName `
            -CliPath $cli) -or
        $fakeMutex.WaitCount -ne 1 -or
        -not $fakeMutex.Released -or -not $fakeMutex.Disposed -or
        -not $mutexTimeoutRejected -or -not $timeoutMutex.Disposed -or
        -not $lateReady -or $timeoutAccepted -or
        -not $trayReady -or $missingTrayAccepted -or
        $customHostUri.AbsoluteUri -cne
            'http://localhost:22445/api/version' -or
        $defaultHostUri.AbsoluteUri -cne
            'http://127.0.0.1:11435/api/version' -or
        $wildcardHostUri.AbsoluteUri -cne
            'http://127.0.0.1:33445/api/version' -or
        -not $wildcardIpv6HostUri.IsLoopback -or
        $wildcardIpv6HostUri.HostNameType -ne [UriHostNameType]::IPv6 -or
        $wildcardIpv6HostUri.Port -ne 33446 -or
        $wildcardIpv6HostUri.AbsolutePath -cne '/api/version' -or
        -not $boundedTimeoutRejected -or
        -not $treeTerminated.Value -or
        -not $boundedProcess.Disposed -or
        $boundedProcess.WaitCalls -ne 2 -or
        -not $taskkillTimeoutRejected -or
        -not $taskkillNonzeroRejected -or
        -not $taskkillExitedRaceAccepted -or
        -not [object]::ReferenceEquals(
            $selectedPrimary.Exception,
            $primaryError.Exception
        ) -or -not [object]::ReferenceEquals(
            $selectedCleanup.Exception,
            $cleanupError.Exception
        ) -or [string]$primaryError.Exception.Data[
            'Repair.OllamaCleanupError'
        ] -cne $cleanupError.Exception.Message -or
        $mutexIndex -lt 0 -or $snapshotIndex -le $mutexIndex -or
        $preStopIndex -le $snapshotIndex -or
        $baselineIndex -le $preStopIndex -or
        $environmentIndex -le $baselineIndex -or
        $raceIndex -le $environmentIndex -or
        $startIndex -le $raceIndex -or
        $cleanupIndex -le $startIndex -or
        $emptyCheckIndex -le $cleanupIndex -or
        $restoreIndex -le $emptyCheckIndex -or
        $removeIndex -le $restoreIndex -or
        $restartIndex -le $removeIndex -or
        $trayWaitIndex -le $restartIndex -or
        $releaseIndex -le $trayWaitIndex -or
        $failureIndex -le $releaseIndex -or
        $source -notmatch '\[AggregateException\]::new' -or
        $parameters.ContainsKey('NoNewWindow') -or
        $parameters.ContainsKey('WindowStyle') -or
        -not $missingRejected -or
        $source -notmatch 'Get-RepairOllamaApplicationExecutable' -or
        $source -notmatch `
            'New-RepairOllamaApplicationStartParameters' -or
        $source -notmatch 'Invoke-RepairBoundedChildProcess' -or
        $source -match '&\s*\$ollama\s+pull' -or
        (Get-Command Invoke-RepairModelManager -ErrorAction Stop).
            Definition -notmatch 'Invoke-RepairBoundedChildProcess' -or
        (Get-Command Invoke-RepairModelManager -ErrorAction Stop).
            Definition -match '&\s*\$powerShellPath' -or
        $source -match $forbiddenPattern -or
        $source -match 'NoNewWindow') {
        throw 'Repair Ollama tray indirme sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaTrayDownload'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaProcessIsolation'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaLateApiSuccess'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaSingleInstance'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaPrimaryError'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaTrayRestore'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaRestoredHostHealth'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaBoundedChildren'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.OllamaConfiguredOwnership'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.TaskkillExitPolicy'
}
function Get-RepairInstalledOllamaReferences {
    param([Parameter(Mandatory)][string]$ModelsRoot)
    $manifestRoot = Join-Path $ModelsRoot 'manifests'
    if (-not (Test-Path -LiteralPath $manifestRoot `
        -PathType Container)) {
        return @()
    }
    $models = [Collections.Generic.List[object]]::new()
    $known = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($file in @(Get-RepairSafeTreeFiles -Root $manifestRoot)) {
        try {
            $relativePath = Get-RepairRelativePath `
                -Root $manifestRoot -Path $file.FullName
            $segments = @(
                $relativePath.Replace('\', '/').Split('/') |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    }
            )
            if ($segments.Count -lt 4 -or
                $segments -contains '.' -or
                $segments -contains '..') {
                throw (Get-RepairText `
                    -Key 'Repair.Error.OllamaManifestIdentity' `
                    -Arguments @($relativePath))
            }
            $registry = $segments[0]
            $tag = $segments[$segments.Count - 1]
            $model = $segments[$segments.Count - 2]
            $namespace = @(
                $segments[1..($segments.Count - 3)]
            ) -join '/'
            $reference = "$registry/$namespace/$model`:$tag"
            if ($registry -ieq 'registry.ollama.ai') {
                $reference = "$namespace/$model`:$tag"
                if ($namespace -ieq 'library') {
                    $reference = "$model`:$tag"
                }
            }
            if ($known.Add($reference)) {
                $totalBytes = [long]0
                try {
                    $manifest = Get-Content -LiteralPath `
                        $file.FullName -Raw -Encoding UTF8 |
                        ConvertFrom-RepairJson
                    foreach ($descriptor in @(
                        @($manifest.config) + @($manifest.layers)
                    )) {
                        $sizeProperty = $descriptor.
                            PSObject.Properties['size']
                        if ($null -ne $sizeProperty -and
                            [long]$sizeProperty.Value -gt 0) {
                            $totalBytes += [long]$sizeProperty.Value
                        }
                    }
                }
                catch {
                    $message = 'Ollama manifest boyutu ' +
                        'okunamadi: {0}'
                    Write-Verbose ($message -f `
                        $_.Exception.Message)
                }
                $models.Add([pscustomobject]@{
                    Reference = $reference
                    TotalBytes = $totalBytes
                })
            }
        }
        catch {
            Add-RepairFailure -Message (
                '{0}: {1}' -f $file.FullName, $_.Exception.Message
            )
            Write-RepairStatus -Level ERROR -Message (Get-RepairText `
                -Key 'Repair.Model.Failed' `
                -Arguments @(
                    $file.FullName,
                    $_.Exception.Message
                ))
        }
    }
    return @($models.ToArray() | Sort-Object Reference)
}
function Get-RepairPortablePackagePathByReference {
    param(
        [Parameter(Mandatory)][string]$PackageModels,
        [Parameter(Mandatory)][string]$Reference
    )
    if (-not (Test-Path -LiteralPath $PackageModels `
        -PathType Container)) {
        return $null
    }
    foreach ($file in @(Get-RepairSafeTreeFiles `
        -Root $PackageModels | Where-Object {
            $_.Name -ieq 'package.json'
        })) {
        try {
            $metadata = Get-Content -LiteralPath $file.FullName `
                -Raw -Encoding UTF8 | ConvertFrom-RepairJson
            if ($metadata.Format -eq 'ollama-portable-model' -and
                [string]$metadata.OllamaReference -ieq $Reference) {
                return $file.Directory.FullName
            }
        }
        catch {
            Write-Verbose ('Model paket bilgisi okunamadi: {0}' -f `
                $_.Exception.Message)
        }
    }
    return $null
}
function Repair-OllamaPackages {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet(
            'PackageToInstalled', 'InstalledToPackage', 'Bidirectional'
        )]
        [string]$Direction,
        [switch]$AuditOnly
    )
    $modelsRoot = Resolve-RepairCanonicalModelPath `
        -Config $Config -Kind Ollama
    $packageModels = Join-Path $PackageRoot 'Models'
    Assert-RepairNoReparsePoint -Path $packageModels
    Assert-RepairRootsDisjoint -Source $packageModels `
        -Target $modelsRoot
    $metadataFiles = if (Test-Path -LiteralPath $packageModels `
        -PathType Container) {
        @(Get-RepairSafeTreeFiles -Root $packageModels |
            Where-Object { $_.Name -ieq 'package.json' })
    }
    else {
        @()
    }
    $knownReferences = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($metadataFile in $metadataFiles) {
        $packagePath = $metadataFile.Directory.FullName
        $metadata = $null
        try {
            Assert-RepairSafeTreePath -Root $packageModels `
                -Path $metadataFile.FullName
            Assert-RepairNoReparsePoint -Path $packagePath
            $metadata = Get-RepairPortablePackageMetadata `
                -PackagePath $packagePath
            if ($null -eq $metadata -or
                $metadata.Format -ne 'ollama-portable-model') {
                continue
            }
            $null = $knownReferences.Add(
                [string]$metadata.OllamaReference
            )
            $packageValid = Test-RepairPortablePackage `
                -PackagePath $packagePath -Metadata $metadata
            $installedValid = Test-RepairInstalledOllamaModel `
                -ModelsRoot $modelsRoot -Metadata $metadata
            $reference = [string]$metadata.OllamaReference
            if ($packageValid -and $installedValid) {
                $script:MatchedCount++
                Write-Verbose (Get-RepairText `
                    -Key 'Repair.Verbose.ModelHealthy' `
                    -Arguments @($reference))
                continue
            }
            $script:DifferentCount++
            if ($AuditOnly) {
                if ($packageValid) {
                    Write-RepairStatus -Level WARN -Message (Get-RepairText `
                        -Key 'Repair.Model.InstalledInvalid' `
                        -Arguments @($reference, $modelsRoot))
                }
                elseif ($installedValid) {
                    Write-RepairStatus -Level WARN -Message (Get-RepairText `
                        -Key 'Repair.Model.PackageInvalid' `
                        -Arguments @($reference, $packagePath))
                }
                else {
                    Write-RepairStatus -Level WARN -Message (Get-RepairText `
                        -Key 'Repair.Model.BothInvalidAudit' `
                        -Arguments @($reference))
                }
                Write-RepairLog -Event 'MODEL_AUDIT_DIFFERENCE' `
                    -Message (Get-RepairText `
                        -Key 'Repair.Log.ModelDifferenceAudited') `
                    -Level WARN -Data @{
                        Model = $reference
                        Type = 'Ollama'
                        PackageValid = $packageValid
                        InstalledValid = $installedValid
                    }
                Add-RepairUnresolved -Message (Get-RepairText `
                    -Key 'Repair.Unresolved.Model' `
                    -Arguments @($reference))
                continue
            }
            if ($Direction -eq 'PackageToInstalled') {
                if ($packageValid -and $Apply) {
                    Invoke-RepairModelManager `
                        -PackageRoot $PackageRoot -Config $Config `
                        -ModelsRoot $modelsRoot `
                        -ExportRoot $packageModels -Action Import `
                        -PackageSelection $packagePath
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                elseif (-not $packageValid) {
                    $message = Get-RepairText `
                        -Key 'Repair.Model.PackageInvalid' `
                        -Arguments @($reference, $packagePath)
                    Write-RepairStatus -Level WARN -Message $message
                    Add-RepairUnresolved -Message $message
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($reference))
                }
                continue
            }
            if ($Direction -eq 'InstalledToPackage') {
                if ($installedValid -and $Apply) {
                    Invoke-RepairModelManager `
                        -PackageRoot $PackageRoot -Config $Config `
                        -ModelsRoot $modelsRoot `
                        -ExportRoot $packageModels -Action Export `
                        -ModelSelection $reference
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                elseif (-not $installedValid) {
                    $message = Get-RepairText `
                        -Key 'Repair.Model.InstalledInvalid' `
                        -Arguments @($reference, $modelsRoot)
                    Write-RepairStatus -Level WARN -Message $message
                    Add-RepairUnresolved -Message $message
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($reference))
                }
                continue
            }
            if ($packageValid) {
                if ($Apply) {
                    Invoke-RepairModelManager `
                        -PackageRoot $PackageRoot -Config $Config `
                        -ModelsRoot $modelsRoot `
                        -ExportRoot $packageModels -Action Import `
                        -PackageSelection $packagePath
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($reference))
                }
                continue
            }
            if ($installedValid) {
                if ($Apply) {
                    Invoke-RepairModelManager `
                        -PackageRoot $PackageRoot -Config $Config `
                        -ModelsRoot $modelsRoot `
                        -ExportRoot $packageModels -Action Export `
                        -ModelSelection $reference
                    if (-not $WhatIfPreference) {
                        $script:ResolvedCount++
                    }
                }
                else {
                    Add-RepairUnresolved -Message (Get-RepairText `
                        -Key 'Repair.Unresolved.Model' `
                        -Arguments @($reference))
                }
                continue
            }
            Write-RepairStatus -Level WARN -Message (Get-RepairText `
                -Key 'Repair.Model.BothInvalid' `
                -Arguments @($reference))
            if ($Apply) {
                Invoke-RepairOllamaPackageDownload `
                    -PackageRoot $PackageRoot `
                    -Config $Config -Reference $reference
                Invoke-RepairModelManager `
                    -PackageRoot $PackageRoot -Config $Config `
                    -ModelsRoot $modelsRoot `
                    -ExportRoot $packageModels -Action Import `
                    -PackageSelection $packagePath
                if (-not $WhatIfPreference) {
                    $script:ResolvedCount++
                }
            }
            else {
                Add-RepairUnresolved -Message (Get-RepairText `
                    -Key 'Repair.Unresolved.Model' `
                    -Arguments @($reference))
            }
        }
        catch {
            $name = if ($null -ne $metadata) {
                [string]$metadata.OllamaReference
            }
            else {
                $packagePath
            }
            Add-RepairFailure -Message (
                '{0}: {1}' -f $name, $_.Exception.Message
            )
            Write-RepairStatus -Level ERROR -Message (Get-RepairText `
                -Key 'Repair.Model.Failed' `
                -Arguments @($name, $_.Exception.Message))
        }
    }
    if ($Direction -notin @(
        'InstalledToPackage', 'Bidirectional'
    )) {
        return
    }
    $installedModels = @(
        Get-RepairInstalledOllamaReferences `
            -ModelsRoot $modelsRoot
    )
    $missingModels = @($installedModels | Where-Object {
        -not $knownReferences.Contains($_.Reference)
    })
    if ($missingModels.Count -eq 0) {
        return
    }
    $script:DifferentCount += $missingModels.Count
    if ($AuditOnly) {
        foreach ($installedModel in $missingModels) {
            Write-RepairStatus -Level WARN -Message (Get-RepairText `
                -Key 'Repair.Ollama.InstalledOnly' `
                -Arguments @($installedModel.Reference))
            Write-RepairLog -Event 'MODEL_AUDIT_INSTALLED_ONLY' `
                -Message (Get-RepairText `
                    -Key 'Repair.Log.InstalledOnlyModelAudited') `
                -Level WARN -Data @{
                    Model = [string]$installedModel.Reference
                    Type = 'Ollama'
                }
            Add-RepairUnresolved -Message (Get-RepairText `
                -Key 'Repair.Unresolved.Model' `
                -Arguments @($installedModel.Reference))
        }
        return
    }
    $exportModels = [Collections.Generic.List[object]]::new()
    foreach ($installedModel in $missingModels) {
        if ([long]$installedModel.TotalBytes -le 0) {
            $catalogModel = @($Config.Models.Catalog |
                Where-Object {
                    [string]$_.Name -ieq
                        [string]$installedModel.Reference
                } | Select-Object -First 1)
            if ($catalogModel.Count -eq 0) {
                $message = Get-RepairText `
                    -Key 'Repair.Error.OllamaSizeUnknown' `
                    -Arguments @($installedModel.Reference)
                Add-RepairFailure -Message $message
                Write-RepairStatus -Level ERROR -Message $message
                continue
            }
            $installedModel.TotalBytes = [long](
                [double]$catalogModel[0].DownloadSizeGB * 1GB
            )
        }
        $exportModels.Add($installedModel)
    }
    if ($exportModels.Count -eq 0) {
        return
    }
    $requiredBytes = [long](($exportModels |
        Measure-Object -Property TotalBytes -Sum).Sum) +
        [long](128MB * $exportModels.Count)
    $driveRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath($packageModels)
    )
    $freeBytes = [IO.DriveInfo]::new($driveRoot).
        AvailableFreeSpace
    if ($Apply -and $freeBytes -lt $requiredBytes) {
        $message = Get-RepairText `
            -Key 'Repair.Error.OllamaExportDiskInsufficient' `
            -Arguments @(
                [math]::Round($requiredBytes / 1GB, 2),
                [math]::Round($freeBytes / 1GB, 2),
                $driveRoot
            )
        Add-RepairFailure -Message $message
        Write-RepairStatus -Level ERROR -Message $message
        return
    }
    foreach ($installedModel in $exportModels) {
        $reference = [string]$installedModel.Reference
        Write-RepairStatus -Level STEP -Message (Get-RepairText `
            -Key 'Repair.Ollama.ExportPlanned' `
            -Arguments @($reference, $packageModels))
        if (-not $Apply) {
            Add-RepairUnresolved -Message (Get-RepairText `
                -Key 'Repair.Unresolved.Model' `
                -Arguments @($reference))
            continue
        }
        try {
            Invoke-RepairModelManager -PackageRoot $PackageRoot `
                -Config $Config -ModelsRoot $modelsRoot `
                -ExportRoot $packageModels -Action Export `
                -ModelSelection $reference
            if (-not $WhatIfPreference) {
                $script:ResolvedCount++
            }
        }
        catch {
            $exportError = $_.Exception.Message
            try {
                if ($Direction -ne 'Bidirectional') {
                    throw
                }
                Invoke-RepairOllamaPackageDownload `
                    -PackageRoot $PackageRoot -Config $Config `
                    -Reference $reference
                $downloadedPackage = `
                    Get-RepairPortablePackagePathByReference `
                        -PackageModels $packageModels `
                        -Reference $reference
                if ([string]::IsNullOrWhiteSpace(
                    $downloadedPackage
                )) {
                    throw (Get-RepairText `
                        -Key 'Repair.Error.PackageMissingAfterDownload' `
                        -Arguments @($reference))
                }
                Invoke-RepairModelManager `
                    -PackageRoot $PackageRoot -Config $Config `
                    -ModelsRoot $modelsRoot `
                    -ExportRoot $packageModels -Action Import `
                    -PackageSelection $downloadedPackage
                if (-not $WhatIfPreference) {
                    $script:ResolvedCount++
                }
            }
            catch {
                $message = '{0}; {1}' -f `
                    $exportError, $_.Exception.Message
                Add-RepairFailure -Message (
                    '{0}: {1}' -f $reference, $message
                )
                Write-RepairStatus -Level ERROR -Message (Get-RepairText `
                    -Key 'Repair.Model.Failed' `
                    -Arguments @($reference, $message))
            }
        }
    }
}
function Invoke-RepairInstalledComfyUIScope {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$ModelDirection,
        [switch]$AuditOnly
    )
    if (-not (Test-RepairConfigurationComponentEnabled `
        -Config $Config -Component 'ComfyUI')) {
        return
    }
    $sourceRuntime = Join-Path $SourceRoot 'Runtime\ComfyUI'
    $targetRuntime = Resolve-RepairComfyUIInstallTarget `
        -Config $Config -InstalledRoot $InstalledRoot `
        -SourceRuntime $sourceRuntime
    Sync-RepairTree -Source $sourceRuntime -Target $targetRuntime `
        -Optional -RuntimePayload -InstalledRuntimeTarget `
        -RuntimeConfig $Config
    Repair-ComfyUIAssets -PackageRoot $SourceRoot -Config $Config `
        -Direction $ModelDirection -AuditOnly:$AuditOnly
}
function Invoke-RepairPostValidation {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('RepairAll', 'PackageToInstalled', 'PublishPackage')]
        [string]$SelectedMode,
        [Parameter(Mandatory)]
        [ValidateSet(
            'PackageToInstalled', 'InstalledToPackage', 'Bidirectional'
        )]
        [string]$ModelDirection,
        [string]$DiskTarget
    )
    $detected = $script:DifferentCount
    $matched = $script:MatchedCount
    $savedApply = $script:Apply
    $savedUnresolved = @($script:UnresolvedItems)
    $savedSkipped = @($script:SkippedItems)
    $remaining = $detected
    $validationUnresolved = @()
    $validationSkipped = @()
    $script:DifferentCount = 0
    $script:ResolvedCount = 0
    $script:MatchedCount = 0
    $script:UnresolvedItems.Clear()
    $script:SkippedItems.Clear()
    $script:Apply = $false
    try {
        if ($SelectedMode -eq 'PublishPackage') {
            Invoke-RepairDiskScope -Source $SourceRoot -Target $TargetRoot `
                -Config $Config
        }
        else {
            Sync-RepairApplicationPayload -Source $SourceRoot `
                -Target $TargetRoot
            $installedConfig = `
                Get-RepairEffectiveInstalledConfiguration `
                    -PackageRoot $SourceRoot `
                    -InstalledRoot $TargetRoot `
                    -PackageConfig $Config
            Invoke-RepairInstalledComfyUIScope -SourceRoot $SourceRoot `
                -InstalledRoot $TargetRoot -Config $installedConfig `
                -ModelDirection $ModelDirection
            Repair-OllamaPackages -PackageRoot $SourceRoot `
                -Config $Config -Direction $ModelDirection
        }
        if ($DiskTarget) {
            Invoke-RepairDiskScope -Source $SourceRoot -Target $DiskTarget `
                -Config $Config
        }
        $remaining = $script:DifferentCount
        $validationUnresolved = @($script:UnresolvedItems)
        $validationSkipped = @($script:SkippedItems)
    }
    finally {
        $script:Apply = $savedApply
        $script:DifferentCount = $detected
        $script:ResolvedCount = [Math]::Max(
            0,
            $detected - [int]$remaining
        )
        $script:RemainingCount = [int]$remaining
        $script:MatchedCount = $matched
        $script:UnresolvedItems.Clear()
        foreach ($item in (@($savedUnresolved) + `
            @($validationUnresolved))) {
            if (-not $script:UnresolvedItems.Contains([string]$item)) {
                $script:UnresolvedItems.Add([string]$item)
            }
        }
        $script:SkippedItems.Clear()
        foreach ($item in (@($savedSkipped) + @($validationSkipped))) {
            if (-not $script:SkippedItems.Contains([string]$item)) {
                $script:SkippedItems.Add([string]$item)
            }
        }
    }
    Write-RepairLog -Event 'POST_REPAIR_VALIDATION_COMPLETED' `
        -Message (Get-RepairText `
            -Key 'Repair.Log.PostValidationCompleted') `
        -Level $(if ($script:RemainingCount -eq 0) {
            'INFO'
        }
        else {
            'WARN'
        }) -Data @{
            Detected = $script:DifferentCount
            Resolved = $script:ResolvedCount
            Remaining = $script:RemainingCount
        }
}
function Get-RepairInstallerArguments {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $arguments = @(
        '-ConfigPath', $ConfigPath,
        '-Resume', '-ForceRepair', '-NoPause',
        '-OptionalErrorMode', 'Stop',
        '-SessionId', $SessionId
    )
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $arguments += '-Verbose'
    }
    return $arguments
}
function Get-RepairWindowsPowerShellPath {
    $windowsDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
    $executable = Join-Path $windowsDirectory `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw (Get-RepairText -Key 'Repair.Error.ScriptMissing' `
            -Arguments @($executable))
    }
    return $executable
}
function New-RepairChildProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $encodedArguments = @($Arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Argument ([string]$_)
    }) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $encodedArguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    return $startInfo
}
function Assert-RepairTaskkillOutcome {
    param(
        [Parameter(Mandatory)][bool]$Completed,
        [int]$ExitCode,
        [bool]$RootExitedBeforeTaskkill
    )
    if (-not $Completed) {
        throw [TimeoutException]::new(
            'taskkill sureci 10 saniyede tamamlanmadi.'
        )
    }
    if ($ExitCode -ne 0 -and -not $RootExitedBeforeTaskkill) {
        throw [InvalidOperationException]::new(
            "taskkill sureci basarisiz oldu: $ExitCode"
        )
    }
}
function Stop-RepairChildProcessTree {
    param(
        [Parameter(Mandatory)][object]$Process,
        [ValidateRange(100, 30000)][int]$WaitMilliseconds = 5000
    )
    $terminationErrors = [Collections.Generic.List[Exception]]::new()
    $rootExitedBeforeTaskkill = $false
    try {
        $rootExitedBeforeTaskkill = [bool]$Process.HasExited
    }
    catch {
    }
    try {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            $killer = $null
            try {
                $killer = Start-Process -FilePath $taskkill `
                    -ArgumentList @('/PID', [string]$Process.Id, '/T', '/F') `
                    -WindowStyle Hidden -PassThru
                $taskkillCompleted = $killer.WaitForExit(10000)
                if (-not $taskkillCompleted) {
                    Stop-Process -Id $killer.Id -Force `
                        -ErrorAction SilentlyContinue
                    $null = $killer.WaitForExit(2000)
                }
                Assert-RepairTaskkillOutcome `
                    -Completed $taskkillCompleted `
                    -ExitCode $(if ($taskkillCompleted) {
                        [int]$killer.ExitCode
                    }
                    else {
                        0
                    }) `
                    -RootExitedBeforeTaskkill $rootExitedBeforeTaskkill
            }
            catch {
                $terminationErrors.Add($_.Exception)
            }
            finally {
                if ($null -ne $killer) {
                    $killer.Dispose()
                }
            }
        }
    }
    catch {
        $terminationErrors.Add($_.Exception)
    }
    try {
        if (-not $Process.WaitForExit($WaitMilliseconds)) {
            Stop-Process -Id $Process.Id -Force `
                -ErrorAction SilentlyContinue
            if (-not $Process.WaitForExit($WaitMilliseconds)) {
                throw "Alt surec agaci kapatilamadi: $($Process.Id)"
            }
        }
    }
    catch {
        $terminationErrors.Add($_.Exception)
    }
    if ($terminationErrors.Count -gt 0) {
        throw [AggregateException]::new(
            'Alt surec agaci sonlandirma hatasi.',
            [Exception[]]$terminationErrors.ToArray()
        )
    }
}
function Invoke-RepairBoundedChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [scriptblock]$ProcessFactory,
        [scriptblock]$TreeTerminator
    )
    $startInfo = New-RepairChildProcessStartInfo `
        -FilePath $FilePath -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory
    $process = if ($null -ne $ProcessFactory) {
        & $ProcessFactory $startInfo
    }
    else {
        $created = [Diagnostics.Process]::new()
        $created.StartInfo = $startInfo
        $created
    }
    if ($null -eq $process) {
        throw 'Alt surec nesnesi olusturulamadi.'
    }
    try {
        if (-not $process.Start()) {
            throw "Alt surec baslatilamadi: $FilePath"
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $terminationError = $null
            try {
                if ($null -ne $TreeTerminator) {
                    & $TreeTerminator $process
                }
                else {
                    Stop-RepairChildProcessTree -Process $process
                }
            }
            catch {
                $terminationError = $_.Exception
            }
            try {
                if (-not $process.WaitForExit(5000) -and
                    $null -eq $terminationError) {
                    $terminationError = [InvalidOperationException]::new(
                        "Alt surec kapanmadi: $($process.Id)"
                    )
                }
            }
            catch {
                if ($null -eq $terminationError) {
                    $terminationError = $_.Exception
                }
            }
            $timeout = [TimeoutException]::new(
                "Alt surec zaman asimina ugradi: $FilePath"
            )
            if ($null -ne $terminationError) {
                $timeout.Data['TerminationError'] = `
                    $terminationError.Message
            }
            throw $timeout
        }
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}
function Invoke-RepairChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$PassResult
    )
    $startInfo = New-RepairChildProcessStartInfo `
        -FilePath $FilePath -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedAt = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) {
            if ($PassResult) {
                return [pscustomobject]@{
                    ExitCode = -1
                    ProcessId = 0
                    StartedAtUtc = $startedAt
                    CompletedAtUtc = [DateTimeOffset]::UtcNow
                }
            }
            return -1
        }
        $processId = $process.Id
        $process.WaitForExit()
        $installerExitCode = $process.ExitCode
        if ($PassResult) {
            return [pscustomobject]@{
                ExitCode = $installerExitCode
                ProcessId = $processId
                StartedAtUtc = $startedAt
                CompletedAtUtc = [DateTimeOffset]::UtcNow
            }
        }
        return $installerExitCode
    }
    finally {
        $process.Dispose()
    }
}
function Assert-RepairExactConfigurationPath {
    param(
        [Parameter(Mandatory)][string]$ConfiguredPath,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$BasePath
    )
    $resolved = Resolve-RepairPath -Path $ConfiguredPath `
        -BasePath $BasePath
    $expected = [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\')
    if ($resolved -ine $expected) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @($resolved))
    }
    Assert-RepairNoReparsePoint -Path $resolved
}
function Assert-RepairEffectiveWritablePathContract {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstalledRoot
    )
    $installed = [IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\')
    $package = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $tempRoot = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetTempPath()) 'Winlama')
    ).TrimEnd('\')
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    $roamingAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($localAppData) -or
        [string]::IsNullOrWhiteSpace($roamingAppData)) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @('APPDATA/LOCALAPPDATA'))
    }
    $ollamaModels = Get-RepairCanonicalUserModelPath -Kind Ollama
    $userProfile = [IO.Path]::GetDirectoryName(
        [IO.Path]::GetDirectoryName($ollamaModels)
    )
    $paths = [ordered]@{
        Root = $installed
        App = $installed
        Data = Join-Path $installed 'Data'
        Logs = Join-Path $installed 'Logs'
        Models = $ollamaModels
        Reports = Join-Path $installed 'Reports'
        Temp = $tempRoot
        State = Join-Path $installed 'Data\state.json'
        EngineLock = Join-Path $installed 'Data\engine.lock'
    }
    foreach ($name in $paths.Keys) {
        $property = $Config.Paths.PSObject.Properties[$name]
        if ($null -eq $property -or
            [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @("Paths.$name"))
        }
        Assert-RepairExactConfigurationPath `
            -ConfiguredPath ([string]$property.Value) `
            -ExpectedPath $paths[$name] -BasePath $installed
    }
    $pathContracts = @(
        [pscustomobject]@{
            Value = [string]$Config.Ollama.InstallPath
            Expected = Join-Path $localAppData 'Programs\Ollama'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.OpenWebUI.RootPath
            Expected = Join-Path $userProfile '.openui'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.ComfyUI.InstallPath
            Expected = Get-RepairCanonicalComfyUIPath
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.ComfyUI.ModelsPath
            Expected = Get-RepairCanonicalUserModelPath -Kind ComfyUI
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.ComfyUI.OutputPath
            Expected = Join-Path $tempRoot 'ComfyUI\output'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.ComfyUI.InputPath
            Expected = Join-Path $tempRoot 'ComfyUI\input'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.ComfyUI.TempPath
            Expected = Join-Path $tempRoot 'ComfyUI\temp'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.Startup.ShortcutPath
            Expected = Join-Path $roamingAppData `
                'Microsoft\Windows\Start Menu\Programs\Startup\Winlama.lnk'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.OpenWebUI.DefaultConfig.Path
            Expected = Join-Path $installed `
                'Data\Configs\openui-config.json'
            Base = $installed
        }
        [pscustomobject]@{
            Value = [string]$Config.Localization.Directory
            Expected = Join-Path $package 'String'
            Base = $package
        }
        [pscustomobject]@{
            Value = [string]$Config.ModelTransfer.ExportDirectory
            Expected = Join-Path $package 'Models'
            Base = $package
        }
        [pscustomobject]@{
            Value = [string]$Config.ModelTransfer.LogPath
            Expected = Join-Path $package 'Logs\model-manager.log'
            Base = $package
        }
    )
    foreach ($contract in $pathContracts) {
        Assert-RepairExactConfigurationPath `
            -ConfiguredPath $contract.Value `
            -ExpectedPath $contract.Expected -BasePath $contract.Base
    }
    if ([string]$Config.Startup.Script -cne 'Start.ps1') {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @([string]$Config.Startup.Script))
    }
    $nativeSearch = @($Config.ModelTransfer.
        NativeModelSearchDirectories)
    if ($nativeSearch.Count -ne 1) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @('ModelTransfer.NativeModelSearchDirectories'))
    }
    Assert-RepairExactConfigurationPath `
        -ConfiguredPath ([string]$nativeSearch[0]) `
        -ExpectedPath $ollamaModels -BasePath $package
    $importSearch = @($Config.ModelTransfer.ImportSearchDirectories)
    if ($importSearch.Count -ne 1) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @('ModelTransfer.ImportSearchDirectories'))
    }
    Assert-RepairExactConfigurationPath `
        -ConfiguredPath ([string]$importSearch[0]) `
        -ExpectedPath (Join-Path $package 'Models') `
        -BasePath $package
    $expectedEnvironmentVariables = @(
        'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_ORIGINS'
    )
    if ((@($Config.Uninstall.EnvironmentVariables) -join '|') -cne
        ($expectedEnvironmentVariables -join '|') -or
        [string]$Config.Uninstall.ResumeTaskName -cne
            'Winlama-Deployment-Resume' -or
        (@($Config.Uninstall.GeneratedDirectories) -join '|') -cne
            'Configs|Data|Logs|Reports|Runtime') {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @('Uninstall'))
    }
    $firewallRules = [ordered]@{
        OllamaLanAllow = 'Winlama-Ollama-LAN'
        WebUILanAllow = 'Winlama-WebUI-LAN'
        OllamaLocalOnly = 'Winlama-Ollama-LocalOnly'
        WebUILocalOnly = 'Winlama-WebUI-LocalOnly'
    }
    foreach ($name in $firewallRules.Keys) {
        if ([string]$Config.Security.FirewallRules.$name -cne
            $firewallRules[$name]) {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @("Security.FirewallRules.$name"))
        }
    }
}
function Merge-RepairInstalledUserIntent {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][object]$InstalledConfig
    )
    foreach ($component in @(
        'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI', 'Startup'
    )) {
        $installedSection = Get-RepairConfigurationSection `
            -Config $InstalledConfig -Name $component
        if ($null -eq $installedSection) {
            continue
        }
        $enabled = $installedSection.PSObject.Properties['Enabled']
        if ($null -ne $enabled -and $enabled.Value -is [bool]) {
            $Configuration.$component.Enabled = [bool]$enabled.Value
        }
    }
    $installation = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'Installation'
    if ($null -ne $installation) {
        $continue = $installation.PSObject.Properties[
            'ContinueOnOptionalError'
        ]
        if ($null -ne $continue -and $continue.Value -is [bool]) {
            $Configuration.Installation.ContinueOnOptionalError = `
                [bool]$continue.Value
        }
    }
    foreach ($sectionName in @('Models', 'ComfyUI')) {
        $installedSection = Get-RepairConfigurationSection `
            -Config $InstalledConfig -Name $sectionName
        if ($null -eq $installedSection) {
            continue
        }
        $source = $installedSection.PSObject.Properties['InstallSource']
        if ($null -ne $source -and [string]$source.Value -cin @(
            'Automatic', 'Local', 'Online'
        )) {
            $Configuration.$sectionName.InstallSource = `
                [string]$source.Value
        }
        $catalogNames = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($model in @($Configuration.$sectionName.Catalog)) {
            $null = $catalogNames.Add([string]$model.Name)
        }
        $requestedProperty = `
            $installedSection.PSObject.Properties['Requested']
        if ($null -eq $requestedProperty) {
            continue
        }
        $requested = @($requestedProperty.Value | ForEach-Object {
            [string]$_
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Sort-Object -Unique)
        if (@($requested | Where-Object {
            -not $catalogNames.Contains($_)
        }).Count -eq 0) {
            $Configuration.$sectionName.Requested = $requested
        }
    }
    $installedModels = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'Models'
    if ($null -ne $installedModels) {
        $selectionMode = $installedModels.PSObject.Properties[
            'SelectionMode'
        ]
        if ($null -ne $selectionMode -and
            [string]$selectionMode.Value -cin @(
                'Automatic', 'Manual', 'Skip'
            )) {
            $Configuration.Models.SelectionMode = `
                [string]$selectionMode.Value
        }
        $localImport = $installedModels.PSObject.Properties[
            'LocalPackageImport'
        ]
        if ($null -ne $localImport) {
            foreach ($name in @(
                'PromptWhenAvailable', 'UseLocalWhenNonInteractive'
            )) {
                $property = $localImport.Value.PSObject.Properties[$name]
                if ($null -ne $property -and $property.Value -is [bool]) {
                    $Configuration.Models.LocalPackageImport.$name = `
                        [bool]$property.Value
                }
            }
        }
    }
    $installedBootstrap = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'Bootstrap'
    if ($null -ne $installedBootstrap) {
        $powerShell = $installedBootstrap.PSObject.Properties['PowerShell']
        if ($null -ne $powerShell) {
            $source = $powerShell.Value.PSObject.Properties['InstallSource']
            if ($null -ne $source -and [string]$source.Value -cin @(
                'Automatic', 'Local', 'Online'
            )) {
                $Configuration.Bootstrap.PowerShell.InstallSource = `
                    [string]$source.Value
            }
        }
    }
    $installedDependencies = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'Dependencies'
    foreach ($dependency in @($Configuration.Dependencies)) {
        $installedDependency = @($installedDependencies |
            Where-Object {
                [string]$_.Name -ceq [string]$dependency.Name
            } | Select-Object -First 1)
        if ($installedDependency.Count -eq 0) {
            continue
        }
        $source = $installedDependency[0].PSObject.Properties[
            'InstallSource'
        ]
        if ($null -ne $source -and [string]$source.Value -cin @(
            'Automatic', 'Local', 'Online'
        )) {
            $dependency.InstallSource = [string]$source.Value
        }
    }
    $installedOpenWebUI = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'OpenWebUI'
    if ($null -ne $installedOpenWebUI) {
        $defaultConfig = $installedOpenWebUI.PSObject.Properties[
            'DefaultConfig'
        ]
        if ($null -ne $defaultConfig) {
            $apply = $defaultConfig.Value.PSObject.Properties[
                'ApplyOnFirstStart'
            ]
            if ($null -ne $apply -and $apply.Value -is [bool]) {
                $Configuration.OpenWebUI.DefaultConfig.
                    ApplyOnFirstStart = [bool]$apply.Value
            }
        }
    }
    $installedRuntime = Get-RepairConfigurationSection `
        -Config $InstalledConfig -Name 'Runtime'
    if ($null -ne $installedRuntime) {
        $priority = $installedRuntime.PSObject.Properties[
            'ProcessPriority'
        ]
        if ($null -ne $priority -and [string]$priority.Value -cin @(
            'Normal', 'AboveNormal', 'High'
        )) {
            $Configuration.Runtime.ProcessPriority = `
                [string]$priority.Value
        }
        foreach ($name in @(
            'StartupInitialDelaySeconds',
            'StartupAfterOllamaDelaySeconds',
            'StartupCompletionDelaySeconds'
        )) {
            $property = $installedRuntime.PSObject.Properties[$name]
            $value = 0
            if ($null -ne $property -and
                [int]::TryParse([string]$property.Value, [ref]$value) -and
                $value -ge 0 -and $value -le 3600) {
                $Configuration.Runtime.$name = $value
            }
        }
        foreach ($name in @(
            'OllamaStartupTimeoutSeconds', 'PollIntervalSeconds',
            'ProgressLogIntervalSeconds', 'ShutdownTimeoutSeconds'
        )) {
            $property = $installedRuntime.PSObject.Properties[$name]
            $value = 0
            if ($null -ne $property -and
                [int]::TryParse([string]$property.Value, [ref]$value) -and
                $value -ge 1 -and $value -le 86400) {
                $Configuration.Runtime.$name = $value
            }
        }
    }
}
function Get-RepairStringSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return -join @($algorithm.ComputeHash($bytes) | ForEach-Object {
            $_.ToString('x2')
        })
    }
    finally {
        $algorithm.Dispose()
    }
}
function Get-RepairEffectiveInstalledConfiguration {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][pscustomobject]$PackageConfig,
        [pscustomobject]$InstalledConfigOverride,
        [AllowEmptyString()][string]$InstalledConfigJsonOverride,
        [switch]$PassResult
    )
    Assert-RepairDestination -Path $InstalledRoot
    $installedConfigPath = Join-Path $InstalledRoot `
        'Data\Configs\config.json'
    $configuration = $PackageConfig | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $installedConfig = $null
    $status = 'Missing'
    $reason = 'Kurulu yapilandirma bulunamadi.'
    $sha256 = ''
    if ($PSBoundParameters.ContainsKey('InstalledConfigJsonOverride')) {
        $sha256 = Get-RepairStringSha256 `
            -Value $InstalledConfigJsonOverride
        try {
            $installedConfig = ConvertFrom-RepairJson `
                -Json $InstalledConfigJsonOverride
            if ($null -eq $installedConfig) {
                throw [IO.InvalidDataException]::new(
                    'Kurulu yapilandirma bos veya null.'
                )
            }
            $status = 'Candidate'
            $reason = ''
        }
        catch {
            $status = 'Malformed'
            $reason = $_.Exception.Message
        }
    }
    elseif ($null -ne $InstalledConfigOverride) {
        $installedConfig = $InstalledConfigOverride
        $status = 'Candidate'
        $reason = ''
    }
    elseif (Test-Path -LiteralPath $installedConfigPath `
        -PathType Leaf) {
        try {
            $sha256 = Get-RepairHash -Path $installedConfigPath
            $installedConfig = Get-Content `
                -LiteralPath $installedConfigPath -Raw -Encoding UTF8 |
                ConvertFrom-RepairJson
            if ($null -eq $installedConfig) {
                throw [IO.InvalidDataException]::new(
                    'Kurulu yapilandirma bos veya null.'
                )
            }
            $status = 'Candidate'
            $reason = ''
        }
        catch {
            $status = 'Malformed'
            $reason = $_.Exception.Message
        }
    }
    if ($null -ne $installedConfig) {
        Merge-RepairInstalledUserIntent `
            -Configuration $configuration `
            -InstalledConfig $installedConfig
        try {
            $null = Test-DeploymentConfiguration `
                -Config $installedConfig
            Assert-RepairEffectiveWritablePathContract `
                -Config $installedConfig -PackageRoot $PackageRoot `
                -InstalledRoot $InstalledRoot
            $status = 'Valid'
        }
        catch {
            $status = 'Unsafe'
            $reason = $_.Exception.Message
        }
    }
    $configuration.Paths.Root = [IO.Path]::GetFullPath(
        $InstalledRoot
    ).TrimEnd('\')
    $configuration.Paths.Models = `
        Get-RepairCanonicalUserModelPath -Kind Ollama
    $configuration.ComfyUI.ModelsPath = `
        Get-RepairCanonicalUserModelPath -Kind ComfyUI
    $resolvedRoot = Resolve-RepairPath `
        -Path ([string]$configuration.Paths.Root) `
        -BasePath $PackageRoot
    if ($resolvedRoot -ine
        [IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\')) {
        throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
            -Arguments @($resolvedRoot))
    }
    $null = Resolve-RepairComfyUIInstallTarget `
        -Config $configuration -InstalledRoot $InstalledRoot `
        -SourceRuntime (Join-Path $PackageRoot 'Runtime\ComfyUI')
    Assert-RepairEffectiveWritablePathContract `
        -Config $configuration -PackageRoot $PackageRoot `
        -InstalledRoot $InstalledRoot
    $null = Test-DeploymentConfiguration -Config $configuration
    if ($reason.Length -gt 512) {
        $reason = $reason.Substring(0, 512)
    }
    $reason = $reason -replace '[\r\n]+', ' '
    if ($PassResult) {
        return [pscustomobject]@{
            Configuration = $configuration
            Status = $status
            Reason = $reason
            Sha256 = $sha256
            Path = $installedConfigPath
        }
    }
    return $configuration
}
function Repair-RepairInstalledConfiguration {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][pscustomobject]$PackageConfig,
        [switch]$Execute
    )
    $result = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $PackageRoot -InstalledRoot $InstalledRoot `
        -PackageConfig $PackageConfig -PassResult
    if ($result.Status -ceq 'Valid') {
        return $result.Configuration
    }
    $hash = if ([string]::IsNullOrWhiteSpace($result.Sha256)) {
        'yok'
    }
    else {
        $result.Sha256
    }
    $message = Get-RepairText `
        -Key 'Repair.Config.CanonicalFallback' `
        -Arguments @($result.Status, $result.Reason, $hash)
    $script:DifferentCount++
    Write-RepairStatus -Level WARN -Message $message
    Write-RepairLog -Event 'INSTALLED_CONFIG_CANONICAL_FALLBACK' `
        -Message $message -Level WARN -Data @{
            Status = $result.Status
            Reason = $result.Reason
            Sha256 = $hash
            Path = $result.Path
        }
    if (-not $Execute) {
        $script:RepairConfigurationEvents.Add($message)
        Add-RepairUnresolved -Message $message
        return $result.Configuration
    }
    $configurationDirectory = Split-Path -Parent $result.Path
    Assert-RepairSafeTreePath -Root $InstalledRoot `
        -Path $configurationDirectory
    [IO.Directory]::CreateDirectory($configurationDirectory) | Out-Null
    Assert-RepairSafeTreePath -Root $InstalledRoot -Path $result.Path
    $temporary = '{0}.winlama-{1}.tmp' -f `
        $result.Path, [guid]::NewGuid().ToString('N')
    try {
        Assert-RepairSafeTreePath -Root $InstalledRoot -Path $temporary
        $json = ConvertTo-StableJson `
            -Value $result.Configuration -Depth 100
        [IO.File]::WriteAllText(
            $temporary,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        $expectedHash = Get-RepairHash -Path $temporary
        Set-RepairAtomicFile -TemporaryPath $temporary `
            -Destination $result.Path
        if (-not (Test-RepairFileHash -Path $result.Path `
            -ExpectedHash $expectedHash)) {
            throw (Get-RepairText `
                -Key 'Repair.Error.CopyHashMismatch' `
                -Arguments @($temporary, $result.Path))
        }
        $verification = Get-RepairEffectiveInstalledConfiguration `
            -PackageRoot $PackageRoot -InstalledRoot $InstalledRoot `
            -PackageConfig $PackageConfig -PassResult
        if ($verification.Status -cne 'Valid') {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @($verification.Reason))
        }
        $script:CopiedCount++
        $script:ResolvedCount++
        $resolvedMessage = Get-RepairText `
            -Key 'Repair.Config.CanonicalRepaired' `
            -Arguments @($result.Status, $result.Reason, $hash)
        $script:RepairConfigurationEvents.Add($resolvedMessage)
        Write-RepairStatus -Level SUCCESS -Message $resolvedMessage
        Write-RepairLog -Event 'INSTALLED_CONFIG_CANONICAL_REPAIRED' `
            -Message $resolvedMessage -Data @{
                PreviousStatus = $result.Status
                PreviousReason = $result.Reason
                PreviousSha256 = $hash
                CurrentSha256 = $expectedHash
                Path = $result.Path
            }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    return $result.Configuration
}
function Get-RepairConfigurationSection {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Config) {
        return $null
    }
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}
function Test-RepairConfigurationComponentEnabled {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Component
    )
    $section = Get-RepairConfigurationSection `
        -Config $Config -Name $Component
    if ($null -eq $section) {
        return $false
    }
    $enabled = $section.PSObject.Properties['Enabled']
    if ($null -eq $enabled -or $enabled.Value -isnot [bool]) {
        return $false
    }
    return [bool]$enabled.Value
}
function Get-RepairConfigurationRequestedNames {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Section
    )
    $configurationSection = Get-RepairConfigurationSection `
        -Config $Config -Name $Section
    if ($null -eq $configurationSection) {
        return @()
    }
    $requested = $configurationSection.PSObject.Properties['Requested']
    if ($null -eq $requested) {
        return @()
    }
    return @($requested.Value | ForEach-Object {
        [string]$_
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Sort-Object -Unique)
}
function Get-RepairConfigurationDegradations {
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )
    $items = [Collections.Generic.List[object]]::new()
    foreach ($component in @('Voice', 'ComfyUI', 'OpenWebUI')) {
        if ((Test-RepairConfigurationComponentEnabled `
            -Config $Before -Component $component) -and
            -not (Test-RepairConfigurationComponentEnabled `
                -Config $After -Component $component)) {
            $items.Add([pscustomobject]@{
                Kind = 'Component'
                Section = $component
                Name = $component
            })
        }
    }
    foreach ($section in @('Models', 'ComfyUI')) {
        $afterNames = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($name in @(Get-RepairConfigurationRequestedNames `
            -Config $After -Section $section)) {
            $null = $afterNames.Add($name)
        }
        foreach ($name in @(Get-RepairConfigurationRequestedNames `
            -Config $Before -Section $section)) {
            if (-not $afterNames.Contains($name)) {
                $items.Add([pscustomobject]@{
                    Kind = 'Model'
                    Section = $section
                    Name = $name
                })
            }
        }
    }
    return $items.ToArray()
}
function Get-RepairInstallerLogSnapshot {
    param([Parameter(Mandatory)][string[]]$Directories)
    $snapshot = @{}
    foreach ($directory in @($Directories | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $directory `
            -PathType Container)) {
            continue
        }
        Assert-RepairNoReparsePoint -Path $directory
        foreach ($file in @(Get-ChildItem -LiteralPath $directory `
            -File -Filter '*.log' -ErrorAction Stop)) {
            Assert-RepairSafeTreePath -Root $directory `
                -Path $file.FullName
            $snapshot[$file.FullName] = [pscustomobject]@{
                Length = [long]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc
            }
        }
    }
    return $snapshot
}
function Test-RepairInstallerDegradationLogRecord {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][int]$InstallerProcessId,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAtUtc,
        [Parameter(Mandatory)][DateTimeOffset]$CompletedAtUtc
    )
    $timestampProperty = $Record.PSObject.Properties['timestamp']
    if ($null -eq $timestampProperty) {
        return $false
    }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$timestampProperty.Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$timestamp
    )) {
        return $false
    }
    if ($timestamp -lt $StartedAtUtc.AddSeconds(-2) -or
        $timestamp -gt $CompletedAtUtc.AddSeconds(2)) {
        return $false
    }
    $eventProperty = $Record.PSObject.Properties['eventCode']
    $eventCode = if ($null -ne $eventProperty) {
        [string]$eventProperty.Value
    }
    else {
        ''
    }
    $recoveryProperty = $Record.PSObject.Properties['recoveryCode']
    $recoveryCode = if ($null -ne $recoveryProperty) {
        [string]$recoveryProperty.Value
    }
    else {
        ''
    }
    if ($recoveryCode -ceq 'OPTIONAL_COMPONENT_DEGRADED') {
        return $true
    }
    if ($eventCode -notmatch '(?i)^Installer\..*Skipped$') {
        return $false
    }
    $processProperty = $Record.PSObject.Properties['processId']
    if ($null -eq $processProperty) {
        return $false
    }
    $processId = 0
    if (-not [int]::TryParse(
        [string]$processProperty.Value,
        [ref]$processId
    )) {
        return $false
    }
    return $processId -eq $InstallerProcessId
}
function Get-RepairInstallerDegradationLogEvents {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][string[]]$Directories,
        [Parameter(Mandatory)][pscustomobject]$ChildResult
    )
    $events = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in @($Directories | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $directory `
            -PathType Container)) {
            continue
        }
        Assert-RepairNoReparsePoint -Path $directory
        foreach ($file in @(Get-ChildItem -LiteralPath $directory `
            -File -Filter '*.log' -ErrorAction Stop)) {
            Assert-RepairSafeTreePath -Root $directory `
                -Path $file.FullName
            $offset = 0L
            if ($Before.ContainsKey($file.FullName)) {
                $previous = $Before[$file.FullName]
                if ($file.Length -eq [long]$previous.Length -and
                    $file.LastWriteTimeUtc -le $previous.LastWriteTimeUtc) {
                    continue
                }
                if ($file.Length -ge [long]$previous.Length) {
                    $offset = [long]$previous.Length
                }
            }
            $stream = [IO.File]::Open(
                $file.FullName,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite
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
                        try {
                            $record = ConvertFrom-RepairJson -Json $line
                        }
                        catch {
                            continue
                        }
                        if (-not (Test-RepairInstallerDegradationLogRecord `
                            -Record $record `
                            -InstallerProcessId $ChildResult.ProcessId `
                            -StartedAtUtc $ChildResult.StartedAtUtc `
                            -CompletedAtUtc $ChildResult.CompletedAtUtc)) {
                            continue
                        }
                        $eventProperty = `
                            $record.PSObject.Properties['eventCode']
                        $recoveryProperty = `
                            $record.PSObject.Properties['recoveryCode']
                        $messageProperty = `
                            $record.PSObject.Properties['message']
                        $code = if ($null -ne $recoveryProperty -and
                            -not [string]::IsNullOrWhiteSpace(
                                [string]$recoveryProperty.Value
                            )) {
                            [string]$recoveryProperty.Value
                        }
                        elseif ($null -ne $eventProperty) {
                            [string]$eventProperty.Value
                        }
                        else {
                            'DEGRADED'
                        }
                        $message = if ($null -ne $messageProperty) {
                            [string]$messageProperty.Value
                        }
                        else {
                            ''
                        }
                        $null = $events.Add(('{0}: {1}' -f `
                            $code, $message).TrimEnd(':', ' '))
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
    }
    return @($events | Sort-Object)
}
function Invoke-RepairInstaller {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    if ($SkipInstaller) {
        $message = Get-RepairText -Key 'Repair.Installer.Skipped'
        Write-RepairStatus -Level SKIP -Message $message
        Add-RepairSkipped -Message $message
        return
    }
    $installer = Join-Path $Root 'Install.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw (Get-RepairText -Key 'Repair.Error.ScriptMissing' `
            -Arguments @('Install.ps1'))
    }
    $configCopy = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $Root -InstalledRoot $InstalledRoot `
        -PackageConfig $Config
    $temporaryBase = [IO.Path]::GetFullPath(
        [IO.Path]::GetTempPath()
    ).TrimEnd('\')
    $temporaryRoot = Join-Path $temporaryBase `
        ('Winlama-Repair-Install-{0}' -f `
            [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $effectiveConfig = Join-Path $temporaryRoot 'config.json'
    [IO.File]::WriteAllText(
        $effectiveConfig,
        ($configCopy | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false)
    )
    Write-RepairStatus -Level STEP -Message (Get-RepairText `
        -Key 'Repair.Installer.Starting')
    $arguments = @(Get-RepairInstallerArguments `
        -ConfigPath $effectiveConfig)
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $installer
    ) + $arguments
    $logDirectories = @(
        (Join-Path ([IO.Path]::GetTempPath()) 'Winlama-Logs'),
        (Join-Path $InstalledRoot 'Logs')
    )
    $logSnapshot = Get-RepairInstallerLogSnapshot `
        -Directories $logDirectories
    try {
        $childResult = Invoke-RepairChildProcess `
            -FilePath (Get-RepairWindowsPowerShellPath) `
            -Arguments $childArguments -WorkingDirectory $Root `
            -PassResult
        if ($childResult.ExitCode -ne 0) {
            throw (Get-RepairText -Key 'Repair.Error.InstallerFailed' `
                -Arguments @($childResult.ExitCode))
        }
        $installedConfigPath = Join-Path $InstalledRoot `
            'Data\Configs\config.json'
        Assert-RepairSafeTreePath -Root $InstalledRoot `
            -Path $installedConfigPath
        if (-not (Test-Path -LiteralPath $installedConfigPath `
            -PathType Leaf)) {
            throw (Get-RepairText `
                -Key 'Repair.Error.InstalledConfigMissing' `
                -Arguments @($installedConfigPath))
        }
        $installedConfig = Get-Content `
            -LiteralPath $installedConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-RepairJson
        $null = Test-DeploymentConfiguration -Config $installedConfig
        Assert-RepairCanonicalModelPaths -Config $installedConfig `
            -PackageRoot $Root
        $null = Resolve-RepairComfyUIInstallTarget `
            -Config $installedConfig -InstalledRoot $InstalledRoot `
            -SourceRuntime (Join-Path $Root 'Runtime\ComfyUI')
        $resolvedInstalledRoot = Resolve-RepairPath `
            -Path ([string]$installedConfig.Paths.Root) `
            -BasePath $Root
        if ($resolvedInstalledRoot -ine
            [IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\')) {
            throw (Get-RepairText -Key 'Repair.Error.TargetUnsafe' `
                -Arguments @($resolvedInstalledRoot))
        }
        foreach ($degradation in @(
            Get-RepairConfigurationDegradations `
                -Before $configCopy -After $installedConfig
        )) {
            $message = if ($degradation.Kind -ceq 'Component') {
                Get-RepairText `
                    -Key 'Repair.Installer.ComponentDegraded' `
                    -Arguments @($degradation.Name)
            }
            else {
                Get-RepairText -Key 'Repair.Installer.ModelDegraded' `
                    -Arguments @(
                        $degradation.Name,
                        $degradation.Section
                    )
            }
            Write-RepairStatus -Level WARN -Message $message
            Add-RepairSkipped -Message $message
        }
        try {
            $degradationEvents = @(
                Get-RepairInstallerDegradationLogEvents `
                    -Before $logSnapshot `
                    -Directories $logDirectories `
                    -ChildResult $childResult
            )
            foreach ($degradationEvent in $degradationEvents) {
                $message = Get-RepairText `
                    -Key 'Repair.Installer.LogDegraded' `
                    -Arguments @($degradationEvent)
                Write-RepairStatus -Level WARN -Message $message
                Add-RepairSkipped -Message $message
            }
        }
        catch {
            $message = Get-RepairText `
                -Key 'Repair.Installer.LogAuditFailed' `
                -Arguments @($_.Exception.Message)
            Write-RepairStatus -Level WARN -Message $message
            Add-RepairSkipped -Message $message
        }
    }
    finally {
        if ((Test-RepairPathWithinRoot -Root $temporaryBase `
            -Path $temporaryRoot) -and
            [IO.Path]::GetFileName($temporaryRoot).StartsWith(
                'Winlama-Repair-Install-',
                [StringComparison]::Ordinal
            )) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
function Get-RepairMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1'; Key = 'Repair.Menu.All';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '2'; Key = 'Repair.Menu.ToInstalled';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '3'; Key = 'Repair.Menu.Publish';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '0'; Key = 'Repair.Menu.Exit';
            Color = 'Gray' }
    )
}
function Assert-RepairMenuContract {
    $items = @(Get-RepairMenuItems)
    $expected = @('1', '2', '3', '0')
    if (($items.Choice -join ',') -ne ($expected -join ',')) {
        throw 'Onarim menusu numaralari veya sirasi gecersiz.'
    }
    $expectedColors = @('Green', 'Cyan', 'Magenta', 'Gray')
    if (($items.Color -join ',') -ne ($expectedColors -join ',')) {
        throw 'Onarim menusu renk sirasi gecersiz.'
    }
    $texts = @()
    $requiredFragments = @{
        'Repair.Menu.All' = 'Iki tarafi'
        'Repair.Menu.ToInstalled' = 'hedefi kaynak paketten'
        'Repair.Menu.Publish' = 'scriptler canonical paketten'
    }
    foreach ($item in $items) {
        $text = Get-RepairText -Key $item.Key
        if ($text -notmatch ('^\s*\[{0}\]\s+\S' -f $item.Choice)) {
            throw "Onarim menu etiketi gecersiz: $($item.Key)"
        }
        if ($requiredFragments.ContainsKey($item.Key) -and
            $text -inotmatch [regex]::Escape(
                $requiredFragments[$item.Key]
            )) {
            throw "Onarim menu kapsami belirsiz: $($item.Key)"
        }
        $texts += $text.Trim()
    }
    if (@($texts | Sort-Object -Unique).Count -ne $items.Count) {
        throw 'Onarim menusunde yinelenen etiket var.'
    }
    if ([string]::IsNullOrWhiteSpace((Get-RepairText `
        -Key 'Common.Prompt.Selection'))) {
        throw 'Onarim secim istemi bos.'
    }
}
function Get-RepairExecutionPolicy {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'PackageToInstalled', 'PublishPackage', 'RepairAll'
        )]
        [string]$SelectedMode
    )
    $policy = switch ($SelectedMode) {
        'RepairAll' {
            [pscustomobject]@{
                ModelDirection = 'Bidirectional'
                ModelAuditOnly = $false
                InvokeInstaller = $true
            }
        }
        'PackageToInstalled' {
            [pscustomobject]@{
                ModelDirection = 'PackageToInstalled'
                ModelAuditOnly = $false
                InvokeInstaller = $true
            }
        }
        'PublishPackage' {
            [pscustomobject]@{
                ModelDirection = 'InstalledToPackage'
                ModelAuditOnly = $false
                InvokeInstaller = $false
            }
        }
    }
    return $policy
}
function Assert-RepairOutcomeContracts {
    $matched = $script:MatchedCount
    $different = $script:DifferentCount
    $resolved = $script:ResolvedCount
    $remaining = $script:RemainingCount
    $failures = @($script:FailedItems)
    $unresolved = @($script:UnresolvedItems)
    $skipped = @($script:SkippedItems)
    try {
        $script:DifferentCount = 0
        $script:ResolvedCount = 0
        $script:RemainingCount = 0
        $script:FailedItems.Clear()
        $script:UnresolvedItems.Clear()
        $script:SkippedItems.Clear()
        if ((Get-RepairOutcome).Name -ne 'Success') {
            throw 'Temiz onarim basarili sayilmadi.'
        }
        if ((Get-RepairExitCode -Outcome Success) -ne 0) {
            throw 'Basarili onarim cikis kodu gecersiz.'
        }
        $script:DifferentCount = 3
        $script:ResolvedCount = 3
        $script:RemainingCount = 0
        if ((Get-RepairOutcome).Name -ne 'Success') {
            throw 'Dogrulanarak giderilen fark basarisiz sayildi.'
        }
        $script:RemainingCount = 1
        if ((Get-RepairOutcome).Name -ne 'Incomplete') {
            throw 'Cozulmemis fark basarili sayildi.'
        }
        if ((Get-RepairExitCode -Outcome Incomplete) -ne 3) {
            throw 'Tamamlanmamis onarim cikis kodu gecersiz.'
        }
        $script:RemainingCount = 0
        $script:SkippedItems.Add('fixture')
        if ((Get-RepairOutcome).Name -ne 'Incomplete') {
            throw 'Atlanan islem basarili sayildi.'
        }
        $script:FailedItems.Add('fixture')
        if ((Get-RepairOutcome).Name -ne 'Failed') {
            throw 'Teknik hata basarili sayildi.'
        }
        if ((Get-RepairExitCode -Outcome Failed) -ne 1) {
            throw 'Basarisiz onarim cikis kodu gecersiz.'
        }
    }
    finally {
        $script:MatchedCount = $matched
        $script:DifferentCount = $different
        $script:ResolvedCount = $resolved
        $script:RemainingCount = $remaining
        $script:FailedItems.Clear()
        foreach ($item in $failures) {
            $script:FailedItems.Add($item)
        }
        $script:UnresolvedItems.Clear()
        foreach ($item in $unresolved) {
            $script:UnresolvedItems.Add($item)
        }
        $script:SkippedItems.Clear()
        foreach ($item in $skipped) {
            $script:SkippedItems.Add($item)
        }
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.OutcomeContracts'
}
function Assert-RepairLogDurabilityContract {
    $savedPath = $script:RepairLogPath
    $savedCount = $script:RepairLogWriteFailureCount
    try {
        $script:RepairLogPath = `
            'X:\WinlamaValidation\repair-write-failure.log'
        Write-RepairLog -Event 'FIXTURE_LOG_WRITE_FAILURE' `
            -Message 'fixture' -Writer {
                param([string]$Path, [string]$Entry)
                throw (('fixture log write failure' + [Environment]::NewLine) +
                    ('x' * 400))
            }
        if ($script:RepairLogWriteFailureCount -ne $savedCount + 1) {
            throw 'Gunluk yazma hatasi yutma sozlesmesi gecersiz.'
        }
    }
    finally {
        $script:RepairLogPath = $savedPath
        $script:RepairLogWriteFailureCount = $savedCount
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.LogWriteDurability'
}
function Assert-RepairAtomicFileContract {
    $destination = 'X:\WinlamaValidation\atomic-target.txt'
    $temporary = 'X:\WinlamaValidation\atomic-temporary.txt'
    $state = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $null = $state.Add($destination)
    $null = $state.Add($temporary)
    $removed = [Collections.Generic.List[string]]::new()
    $moveHandler = {
        param([string]$Source, [string]$Target)
        if ($Source -ieq $temporary) {
            throw 'fixture commit failure'
        }
        if ($Source -like '*.backup') {
            throw 'fixture restore failure'
        }
        if (-not $state.Remove($Source)) {
            throw "fixture source missing: $Source"
        }
        $null = $state.Add($Target)
    }.GetNewClosure()
    $pathTester = {
        param([string]$Path)
        return $state.Contains($Path)
    }.GetNewClosure()
    $removeHandler = {
        param([string]$Path)
        $removed.Add($Path)
        $null = $state.Remove($Path)
    }.GetNewClosure()
    $failure = $null
    try {
        Set-RepairAtomicFile -TemporaryPath $temporary `
            -Destination $destination -MoveHandler $moveHandler `
            -RemoveHandler $removeHandler -PathTester $pathTester
    }
    catch {
        $failure = $_
    }
    $backup = @($state | Where-Object {
        $_ -like '*.backup'
    })
    if ($null -eq $failure -or $backup.Count -ne 1 -or
        $removed.Contains($backup[0]) -or
        $failure.Exception.Message -notlike "*$($backup[0])*" -or
        $state.Contains($destination)) {
        throw 'Atomik geri yukleme hatasi yedek koruma testi basarisiz.'
    }
    $state.Clear()
    $removed.Clear()
    $null = $state.Add($destination)
    $null = $state.Add($temporary)
    $restoreMoveHandler = {
        param([string]$Source, [string]$Target)
        if ($Source -ieq $temporary) {
            throw 'fixture commit failure'
        }
        if (-not $state.Remove($Source)) {
            throw "fixture source missing: $Source"
        }
        $null = $state.Add($Target)
    }.GetNewClosure()
    try {
        Set-RepairAtomicFile -TemporaryPath $temporary `
            -Destination $destination `
            -MoveHandler $restoreMoveHandler `
            -RemoveHandler $removeHandler -PathTester $pathTester
        throw 'Atomik commit hatasi disariya aktarilmadi.'
    }
    catch {
        if ($_.Exception.Message -notlike '*fixture commit failure*') {
            throw
        }
    }
    if (-not $state.Contains($destination) -or
        @($state | Where-Object { $_ -like '*.backup' }).Count -ne 0) {
        throw 'Atomik basarisiz commit geri yukleme testi basarisiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.AtomicRecovery'
}
function Assert-RepairRuntimeTargetSafetyContract {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $fixtureRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath($PSScriptRoot)
    )
    $packageRoot = Join-Path $fixtureRoot `
        'WinlamaValidation\Package'
    $installedRoot = Join-Path $fixtureRoot `
        'WinlamaValidation\Installed\Winlama'
    $canonical = Join-Path $fixtureRoot `
        'WinlamaValidation\Programs\ComfyUI'
    $fixture = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $fixture.ComfyUI.InstallPath = $canonical
    $sourceRuntime = Join-Path $packageRoot 'Runtime\ComfyUI'
    $resolved = Resolve-RepairComfyUIInstallTarget `
        -Config $fixture -InstalledRoot $installedRoot `
        -SourceRuntime $sourceRuntime -CanonicalPath $canonical
    if ($resolved -ine [IO.Path]::GetFullPath($canonical)) {
        throw 'ComfyUI canonical hedef kabul testi basarisiz.'
    }
    $malicious = $fixture | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $malicious.ComfyUI.InstallPath = `
        (Join-Path $fixtureRoot 'Windows\System32')
    $rejected = $false
    try {
        $null = Resolve-RepairComfyUIInstallTarget `
            -Config $malicious -InstalledRoot $installedRoot `
            -SourceRuntime $sourceRuntime -CanonicalPath $canonical
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'ComfyUI guvensiz hedef mutasyondan once reddedilmedi.'
    }
    foreach ($kind in @('ComfyUI', 'Ollama')) {
        $modelFixture = $Config | ConvertTo-Json -Depth 100 |
            ConvertFrom-RepairJson
        $modelCanonical = Join-Path $fixtureRoot `
            "WinlamaValidation\Models\$kind"
        if ($kind -eq 'ComfyUI') {
            $modelFixture.ComfyUI.ModelsPath = `
                (Join-Path $fixtureRoot 'Windows\System32')
        }
        else {
            $modelFixture.Paths.Models = `
                (Join-Path $fixtureRoot 'Windows\System32')
        }
        $rejected = $false
        try {
            $null = Resolve-RepairCanonicalModelPath `
                -Config $modelFixture -Kind $kind `
                -CanonicalPath $modelCanonical
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "$kind guvensiz model hedefi reddedilmedi."
        }
    }
    $overlap = $fixture | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $overlap.ComfyUI.InstallPath = $sourceRuntime
    $rejected = $false
    try {
        $null = Resolve-RepairComfyUIInstallTarget `
            -Config $overlap -InstalledRoot $installedRoot `
            -SourceRuntime $sourceRuntime `
            -CanonicalPath $sourceRuntime
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'ComfyUI cakisan kaynak ve hedef reddedilmedi.'
    }
    $redirected = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $redirected.Paths.Root = Join-Path $fixtureRoot `
        'WinlamaValidation\Redirected\Winlama'
    $redirected.Paths.Models = Join-Path $fixtureRoot `
        'Windows\System32'
    foreach ($name in @(
        'App', 'Data', 'Logs', 'Reports', 'Temp', 'State',
        'EngineLock'
    )) {
        $redirected.Paths.$name = Join-Path $fixtureRoot `
            'Windows\System32'
    }
    $redirected.Ollama.InstallPath = Join-Path $fixtureRoot `
        'Windows\System32'
    $redirected.OpenWebUI.RootPath = Join-Path $fixtureRoot `
        'Windows\System32'
    $redirected.ComfyUI.InstallPath = Join-Path $fixtureRoot `
        'Windows\System32'
    $redirected.ComfyUI.ModelsPath = Join-Path $fixtureRoot `
        'Windows\System32'
    foreach ($name in @('OutputPath', 'InputPath', 'TempPath')) {
        $redirected.ComfyUI.$name = Join-Path $fixtureRoot `
            'Windows\System32'
    }
    $redirected.Startup.ShortcutPath = Join-Path $fixtureRoot `
        'Windows\System32\Winlama.lnk'
    $redirected.Startup.Script = 'Windows.ps1'
    $redirected.Uninstall.ResumeTaskName = 'Windows-System-Task'
    $redirected.Uninstall.EnvironmentVariables = @('PATH')
    $redirected.Security.FirewallRules.OllamaLanAllow = `
        'Windows-System-Rule'
    $effective = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $packageRoot -InstalledRoot $installedRoot `
        -PackageConfig $Config `
        -InstalledConfigOverride $redirected
    if ([IO.Path]::GetFullPath([string]$effective.Paths.Root) -ine
        [IO.Path]::GetFullPath($installedRoot)) {
        throw 'Kurulu yapilandirma hedef kok yeniden baglama testi basarisiz.'
    }
    if ((Resolve-RepairCanonicalModelPath `
        -Config $effective -Kind Ollama) -ine
        (Get-RepairCanonicalUserModelPath -Kind Ollama) -or
        (Resolve-RepairCanonicalModelPath `
            -Config $effective -Kind ComfyUI) -ine
        (Get-RepairCanonicalUserModelPath -Kind ComfyUI)) {
        throw 'Kurulu model hedefi canonical yeniden baglanamadi.'
    }
    Assert-RepairEffectiveWritablePathContract `
        -Config $effective -PackageRoot $packageRoot `
        -InstalledRoot $installedRoot
    $missingRoot = Join-Path $fixtureRoot `
        ('WinlamaValidation\Missing-{0}\Winlama' -f `
            [guid]::NewGuid().ToString('N'))
    $missingResult = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $packageRoot -InstalledRoot $missingRoot `
        -PackageConfig $Config -PassResult
    if ($missingResult.Status -cne 'Missing') {
        throw 'Eksik kurulu config canonical fallback testi basarisiz.'
    }
    $malformedResult = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $packageRoot -InstalledRoot $missingRoot `
        -PackageConfig $Config -InstalledConfigJsonOverride '{' `
        -PassResult
    if ($malformedResult.Status -cne 'Malformed' -or
        [string]::IsNullOrWhiteSpace($malformedResult.Sha256)) {
        throw 'Bozuk kurulu config canonical fallback testi basarisiz.'
    }
    $redirected.Voice.Enabled = $false
    $preservedModel = [string]@($Config.Models.Requested)[0]
    $redirected.Models.Requested = @($preservedModel)
    $unsafeResult = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $packageRoot -InstalledRoot $installedRoot `
        -PackageConfig $Config `
        -InstalledConfigOverride $redirected -PassResult
    if ($unsafeResult.Status -cne 'Unsafe' -or
        $unsafeResult.Configuration.Voice.Enabled -or
        $preservedModel -notin @(
            $unsafeResult.Configuration.Models.Requested
        )) {
        throw 'Guvensiz config intent whitelist fallback testi basarisiz.'
    }
    Assert-RepairEffectiveWritablePathContract `
        -Config $unsafeResult.Configuration `
        -PackageRoot $packageRoot -InstalledRoot $installedRoot
    $validIntent = $missingResult.Configuration |
        ConvertTo-Json -Depth 100 | ConvertFrom-RepairJson
    $validIntent.Voice.Enabled = $false
    $validResult = Get-RepairEffectiveInstalledConfiguration `
        -PackageRoot $packageRoot -InstalledRoot $missingRoot `
        -PackageConfig $Config `
        -InstalledConfigOverride $validIntent -PassResult
    if ($validResult.Status -cne 'Valid' -or
        $validResult.Configuration.Voice.Enabled) {
        throw 'Gecerli kurulu config intent koruma testi basarisiz.'
    }
    $maliciousPolicy = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $maliciousPolicy.Paths.Temp = Join-Path $fixtureRoot `
        'Windows\System32'
    $rejected = $false
    try {
        $null = Get-RepairEffectiveInstalledConfiguration `
            -PackageRoot $packageRoot -InstalledRoot $installedRoot `
            -PackageConfig $maliciousPolicy `
            -InstalledConfigOverride $redirected
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'Guvensiz package writable path mutasyondan once reddedilmedi.'
    }
    $protectedTarget = Join-Path (
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::Windows
        )
    ) 'System32\Winlama'
    $rejected = $false
    try {
        Assert-RepairDestination -Path $protectedTarget
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'Korunan Windows altinda Winlama hedefi reddedilmedi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.ConfigFallback'
    $reparseProvider = {
        param([string]$Path)
        if ($Path -like '*\Link') {
            return [pscustomobject]@{
                Attributes = [IO.FileAttributes]::ReparsePoint
            }
        }
        return $null
    }
    $rejected = $false
    try {
        Assert-RepairNoReparsePoint `
            -Path (Join-Path $fixtureRoot 'Safe\Link\Target') `
            -ItemProvider $reparseProvider
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'Reparse point hedefi reddedilmedi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.RuntimeTargetSafety'
}
function Assert-RepairInstallerDegradationContract {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    foreach ($key in @(
        'Repair.Error.InstalledConfigMissing',
        'Repair.Installer.ComponentDegraded',
        'Repair.Installer.ModelDegraded',
        'Repair.Installer.LogDegraded',
        'Repair.Installer.LogAuditFailed'
    )) {
        $value = Get-RepairText -Key $key
        if ([string]::IsNullOrWhiteSpace($value) -or $value -ceq $key) {
            throw "Installer bozulma yerellestirmesi eksik: $key"
        }
    }
    $before = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $after = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-RepairJson
    $after.Voice.Enabled = $false
    $missingOllamaModel = [string]@($before.Models.Requested)[0]
    $missingComfyModel = [string]@($before.ComfyUI.Requested)[0]
    $after.Models.Requested = @($after.Models.Requested |
        Where-Object { [string]$_ -ine $missingOllamaModel })
    $after.ComfyUI.Requested = @($after.ComfyUI.Requested |
        Where-Object { [string]$_ -ine $missingComfyModel })
    $degradations = @(Get-RepairConfigurationDegradations `
        -Before $before -After $after)
    $identities = @($degradations | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Kind, $_.Section, $_.Name
    })
    foreach ($expected in @(
        'Component|Voice|Voice',
        "Model|Models|$missingOllamaModel",
        "Model|ComfyUI|$missingComfyModel"
    )) {
        if ($expected -notin $identities) {
            throw "Installer bozulma karsilastirmasi eksik: $expected"
        }
    }
    if (@(Get-RepairConfigurationDegradations `
        -Before $before -After $before).Count -ne 0) {
        throw 'Degismeyen installer yapilandirmasi bozulmus sayildi.'
    }
    $now = [DateTimeOffset]::UtcNow
    $skippedRecord = [pscustomobject]@{
        timestamp = $now.ToString('O')
        eventCode = 'Installer.ComfyUI.ModelsSkipped'
        recoveryCode = ''
        processId = 42
    }
    if (-not (Test-RepairInstallerDegradationLogRecord `
        -Record $skippedRecord -InstallerProcessId 42 `
        -StartedAtUtc $now.AddSeconds(-1) `
        -CompletedAtUtc $now.AddSeconds(1)) -or
        (Test-RepairInstallerDegradationLogRecord `
            -Record $skippedRecord -InstallerProcessId 41 `
            -StartedAtUtc $now.AddSeconds(-1) `
            -CompletedAtUtc $now.AddSeconds(1))) {
        throw 'Installer Skipped PID/zaman korelasyonu gecersiz.'
    }
    $recoveryRecord = [pscustomobject]@{
        timestamp = $now.ToString('O')
        eventCode = 'Engine.OptionalComponent'
        recoveryCode = 'OPTIONAL_COMPONENT_DEGRADED'
        processId = 84
    }
    if (-not (Test-RepairInstallerDegradationLogRecord `
        -Record $recoveryRecord -InstallerProcessId 42 `
        -StartedAtUtc $now.AddSeconds(-1) `
        -CompletedAtUtc $now.AddSeconds(1)) -or
        (Test-RepairInstallerDegradationLogRecord `
            -Record $recoveryRecord -InstallerProcessId 42 `
            -StartedAtUtc $now.AddMinutes(1) `
            -CompletedAtUtc $now.AddMinutes(2))) {
        throw 'Installer degraded recovery zaman korelasyonu gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Repair.InstallerDegradationDetection'
}
function Assert-RepairInstallerContract {
    $fixtureConfig = 'X:\WinlamaValidation\config.json'
    $arguments = @(Get-RepairInstallerArguments `
        -ConfigPath $fixtureConfig)
    $sessionIndex = [array]::IndexOf($arguments, '-SessionId')
    if ($arguments.Count -lt 5 -or
        $arguments[0] -cne '-ConfigPath' -or
        $arguments[1] -cne $fixtureConfig -or
        '-Resume' -notin $arguments -or
        '-ForceRepair' -notin $arguments -or
        '-NoPause' -notin $arguments -or
        '-OptionalErrorMode' -notin $arguments -or
        'Stop' -notin $arguments -or
        $sessionIndex -lt 0 -or
        $sessionIndex + 1 -ge $arguments.Count -or
        $arguments[$sessionIndex + 1] -cne $SessionId -or
        @($arguments | Where-Object {
            $_ -match '(?i)Prompt'
        }).Count -gt 0) {
        throw 'Install.ps1 noninteractive onarim devri gecersiz.'
    }
    $fixtureStartInfo = New-RepairChildProcessStartInfo `
        -FilePath (Get-RepairWindowsPowerShellPath) `
        -Arguments @('-NoLogo') -WorkingDirectory $PSScriptRoot
    if ($fixtureStartInfo.CreateNoWindow -or
        $fixtureStartInfo.UseShellExecute) {
        throw 'Install.ps1 gorunur parent konsol sozlesmesi gecersiz.'
    }
    $fixtureExitCode = Invoke-RepairChildProcess `
        -FilePath (Get-RepairWindowsPowerShellPath) `
        -Arguments @(
            '-NoLogo', '-NoProfile', '-Command', 'exit 7'
        ) -WorkingDirectory $PSScriptRoot
    if ($fixtureExitCode -ne 7) {
        throw 'Install.ps1 alt surec cikis kodu okunamadi.'
    }
    $sourceText = [IO.File]::ReadAllText($PSCommandPath)
    $invokeIndex = $sourceText.LastIndexOf(
        'Invoke-RepairInstaller -Root $packageRoot',
        [StringComparison]::Ordinal
    )
    $validationIndex = $sourceText.LastIndexOf(
        'Invoke-RepairPostValidation -SourceRoot $packageRoot',
        [StringComparison]::Ordinal
    )
    if ($invokeIndex -lt 0 -or $validationIndex -le $invokeIndex) {
        throw 'Installer veya onarim sonrasi dogrulama sirasi gecersiz.'
    }
    foreach ($requiredSource in @(
        '[Diagnostics.Process]::new()',
        '$process.WaitForExit()',
        '$installerExitCode = $process.ExitCode',
        "'-NonInteractive'",
        'Get-RepairEffectiveInstalledConfiguration',
        '$configuration.Paths.Root ='
    )) {
        if ($sourceText.IndexOf(
            $requiredSource,
            [StringComparison]::Ordinal
        ) -lt 0) {
            throw 'Install.ps1 ayri surec bekleme sozlesmesi gecersiz.'
        }
    }
    $directCall = '& $' + 'installer @arguments'
    if ($sourceText.Contains($directCall)) {
        throw 'Install.ps1 mevcut Repair.ps1 runspace icinde cagrilamaz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.NonInteractiveInstaller'
}
function Assert-RepairCancellationContract {
    $sourceText = [IO.File]::ReadAllText($PSCommandPath)
    $cancelIndex = $sourceText.LastIndexOf(
        "Write-RepairLog -Event 'REPAIR_CANCELLED'",
        [StringComparison]::Ordinal
    )
    $exitIndex = if ($cancelIndex -ge 0) {
        $sourceText.IndexOf(
            'exit 2',
            $cancelIndex,
            [StringComparison]::Ordinal
        )
    }
    else {
        -1
    }
    $policyIndex = $sourceText.LastIndexOf(
        '$executionPolicy = Get-RepairExecutionPolicy',
        [StringComparison]::Ordinal
    )
    if ($cancelIndex -lt 0 -or $exitIndex -le $cancelIndex -or
        $policyIndex -le $exitIndex -or
        (Get-RepairExitCode -Outcome Incomplete) -eq 2) {
        throw 'Onarim iptal cikis kodu veya gunluk sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.CancelExitCode'
}
function Assert-RepairReportLocalizationContract {
    $keys = @(
        'Repair.Report.PageTitle', 'Repair.Report.Start',
        'Repair.Report.End', 'Repair.Report.Outcome',
        'Repair.Report.Outcome.Success',
        'Repair.Report.Outcome.Incomplete',
        'Repair.Report.Outcome.Failed', 'Repair.Report.Mode',
        'Repair.Report.Mode.RepairAll',
        'Repair.Report.Mode.PackageToInstalled',
        'Repair.Report.Mode.PublishPackage', 'Repair.Report.Source',
        'Repair.Report.Target', 'Repair.Report.Matched',
        'Repair.Report.Detected', 'Repair.Report.Resolved',
        'Repair.Report.Remaining', 'Repair.Report.Copied',
        'Repair.Report.Deleted', 'Repair.Report.Skipped',
        'Repair.Report.FailedLabel', 'Repair.Report.Log',
        'Repair.Report.UnresolvedTitle',
        'Repair.Report.SkippedTitle',
        'Repair.Report.FailuresTitle',
        'Repair.Report.ConfigRepairsTitle',
        'Repair.Report.Empty.Unresolved',
        'Repair.Report.Empty.Skipped',
        'Repair.Report.Empty.Failures',
        'Repair.Report.Empty.ConfigRepairs',
        'Repair.Config.CanonicalFallback',
        'Repair.Config.CanonicalRepaired'
    )
    foreach ($key in $keys) {
        $value = Get-RepairText -Key $key
        if ([string]::IsNullOrWhiteSpace($value) -or $value -ceq $key) {
            throw "Onarim raporu yerellestirme anahtari eksik: $key"
        }
    }
    $sourceText = [IO.File]::ReadAllText($PSCommandPath)
    if ($sourceText -match '<th>[A-Za-z]' -or
        $sourceText -match '<h[12]>[A-Za-z]') {
        throw 'Onarim raporunda hardcoded kullanici metni bulundu.'
    }
    if (Invoke-RepairNoThrowNotification `
        -Context 'fixture post-commit notification' `
        -Action { throw 'fixture notification failure' }) {
        throw 'Rapor commit sonrasi bildirim hatasi yutulmadi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.ReportLocalization'
}
function Show-RepairMenu {
    Write-RepairRule -Character '='
    Write-RepairLine -Text (Get-RepairText `
        -Key 'Repair.Menu.Title') -Color Cyan
    Write-RepairLine -Text (Get-RepairText `
        -Key 'Repair.Menu.Summary') -Color Cyan
    Write-RepairRule -Character '='
    foreach ($item in @(Get-RepairMenuItems)) {
        Write-RepairLine -Text (Get-RepairText -Key $item.Key) `
            -Color $item.Color
    }
    Write-RepairRule
}
function Select-RepairMode {
    param(
        [ValidateSet(
            'Menu', 'PackageToInstalled', 'PublishPackage', 'RepairAll'
        )]
        [string]$RequestedMode = $Mode,
        [scriptblock]$InputReader
    )
    if ($RequestedMode -ne 'Menu') {
        return $RequestedMode
    }
    Show-RepairMenu
    while ($true) {
        $selection = Read-RepairInput -Prompt (Get-RepairText `
            -Key 'Common.Prompt.Selection') -InputReader $InputReader `
            -NoLeadingRule
        switch ($selection) {
            '1' { return 'RepairAll' }
            '2' { return 'PackageToInstalled' }
            '3' { return 'PublishPackage' }
            '0' { return $null }
            default {
                Write-RepairStatus -Level WARN `
                    -Message (Get-RepairText `
                        -Key 'Common.Selection.Invalid')
            }
        }
    }
}
$exitCode = 0
try {
    . (Join-Path $PSScriptRoot 'Modules\Repair\DiskScope.ps1')
    $ConfigPath = Resolve-RepairConfigPath -Path $ConfigPath
    Initialize-RepairLocalization -Path $ConfigPath
    if ($Preview -and ($Apply -or $GenerateReport -or $Mode -eq 'Menu' -or
        ($Mode -eq 'PublishPackage' -and -not $DestinationRoot))) {
        throw (Get-RepairText -Key 'Repair.Error.PreviewConflict')
    }
    Initialize-RepairCommon
    Write-Verbose (Get-RepairText `
        -Key 'Repair.Verbose.ValidationStarted')
    $localConfig = Get-Content -LiteralPath $ConfigPath -Raw `
        -Encoding UTF8 | ConvertFrom-RepairJson
    foreach ($property in @(
        'Paths', 'Models', 'ModelTransfer',
        'ComfyUI', 'Ollama', 'EngineVersion'
    )) {
        if ($null -eq $localConfig.PSObject.Properties[$property]) {
            throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
                -Arguments @($property))
        }
    }
    foreach ($file in @(
        'Install.ps1', 'Engine.ps1', 'Launcher.ps1',
        'ModelManager.ps1', 'Repair.ps1', 'Start.ps1',
        'Uninstall.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) `
            -PathType Leaf)) {
            throw (Get-RepairText -Key 'Repair.Error.ScriptMissing' `
                -Arguments @($file))
        }
    }
    Assert-RepairCanonicalModelPaths -Config $localConfig `
        -PackageRoot $PSScriptRoot
    $officialModelPrefixes = @(
        Get-RepairOfficialModelUriPrefixes -Config $localConfig
    )
    $auditModelPrefixes = @(
        Get-RepairOfficialModelUriPrefixes -Config $localConfig `
            -PropertyName 'AuditModelUriPrefixes'
    )
    Assert-RepairModelCatalog -Config $localConfig `
        -OfficialPrefixes $officialModelPrefixes `
        -AuditPrefixes $auditModelPrefixes `
        -Root $PSScriptRoot
    Assert-RepairComfyUIRuntimeContracts -Config $localConfig
    if (-not $ValidateOnly -and -not $Preview) {
        $deploymentRoot = Resolve-RepairPath `
            -Path ([string]$localConfig.Paths.Root) `
            -BasePath $PSScriptRoot
        Initialize-RepairDiagnostics -Root $deploymentRoot `
            -LogsPath ([string]$localConfig.Paths.Logs) `
            -ReportsPath ([string]$localConfig.Paths.Reports)
        Write-RepairLog -Event 'PROCESS_STARTED' `
            -Message (Get-RepairText -Key 'Repair.Log.Started') `
            -Data @{ Mode = $Mode;
                Apply = [bool]$Apply;
                SourceRoot = $SourceRoot;
                DestinationRoot = $DestinationRoot;
                ProcessId = $PID }
    }
    Write-Verbose (Get-RepairText `
        -Key 'Repair.Verbose.ValidationCompleted')
    if ($ValidateOnly) {
        $null = Assert-WinlamaUIStandard
        $null = Assert-RepairBootstrapInputContracts
        $null = Assert-WinlamaUIInputFormatter -Formatter {
            param([string]$Value)
            Format-RepairBootstrapInputLine -Value $Value
        }
        Assert-RepairMenuContract
        Assert-RepairApplicationSafetyContract
        Assert-RepairApplyPostValidationContract
        Assert-RepairOutcomeContracts
        Assert-RepairLogDurabilityContract
        Assert-RepairAtomicFileContract
        Assert-RepairRuntimeTargetSafetyContract -Config $localConfig
        Assert-RepairOllamaApplicationContract
        Assert-RepairInstallerDegradationContract -Config $localConfig
        Assert-RepairInstallerContract
        Assert-RepairCancellationContract
        Assert-RepairReportLocalizationContract
        Write-Verbose 'WINLAMA_REPAIR_SAFETY_OK:CanonicalSource'
        $modeQueue = [Collections.Generic.Queue[string]]::new()
        $modeQueue.Enqueue('')
        $modeQueue.Enqueue('1')
        $validatedMode = Select-RepairMode -RequestedMode Menu `
            -InputReader { $modeQueue.Dequeue() }.GetNewClosure()
        if ($validatedMode -ne 'RepairAll') {
            throw 'Onarim menu secim dali dogrulanamadi.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Repair.Main'
        $sourceQueue = [Collections.Generic.Queue[string]]::new()
        $sourceQueue.Enqueue('')
        $sourceQueue.Enqueue('2')
        $validatedSource = Select-RepairPackageRoot -Candidates @(
            'X:\WinlamaValidation\SourceA',
            'X:\WinlamaValidation\SourceB'
        ) -InputReader { $sourceQueue.Dequeue() }.GetNewClosure()
        if ($validatedSource -ine 'X:\WinlamaValidation\SourceB') {
            throw 'Onarim kaynak secim dali dogrulanamadi.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Repair.SourceSelection'
        $validationDestination = Join-Path (
            [IO.Path]::GetPathRoot(
                [IO.Path]::GetFullPath($PSScriptRoot)
            )
        ) 'WinlamaValidation\Destination\Winlama'
        $destinationQueue = [Collections.Generic.Queue[string]]::new()
        $destinationQueue.Enqueue('')
        $destinationQueue.Enqueue($validationDestination)
        $validatedDestination = Resolve-RepairDestinationRoot `
            -InputReader {
                $destinationQueue.Dequeue()
            }.GetNewClosure()
        if ($validatedDestination -ine $validationDestination) {
            throw 'Onarim hedef secim dali dogrulanamadi.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Repair.DestinationPrompt'
        $confirmationQueue = [Collections.Generic.Queue[string]]::new()
        $confirmationQueue.Enqueue('')
        $confirmationQueue.Enqueue('EVET')
        $validatedConfirmation = Confirm-RepairAction `
            -Prompt (Get-RepairText -Key 'Repair.Prompt.Apply') `
            -InputReader {
                $confirmationQueue.Dequeue()
            }.GetNewClosure()
        if (-not $validatedConfirmation) {
            throw 'Onarim onay dali dogrulanamadi.'
        }
        $declineQueue = [Collections.Generic.Queue[string]]::new()
        $declineQueue.Enqueue('')
        $declineQueue.Enqueue('HAYIR')
        if (Confirm-RepairAction `
            -Prompt (Get-RepairText -Key 'Repair.Prompt.Apply') `
            -InputReader {
                $declineQueue.Dequeue()
            }.GetNewClosure()) {
            throw 'Onarim HAYIR onay dali dogrulanamadi.'
        }
        Write-Verbose 'WINLAMA_UI_OK:Repair.ApplyPrompt'
        Write-RepairStatus -Level SUCCESS -Message (Get-RepairText `
            -Key 'Repair.Validation.Completed')
        Write-Verbose 'WINLAMA_VALIDATION_OK:Repair.ps1'
        exit 0
    }
    $selectedMode = Select-RepairMode
    if ([string]::IsNullOrWhiteSpace($selectedMode)) {
        Write-RepairLog -Event 'REPAIR_CANCELLED' `
            -Message (Get-RepairText `
                -Key 'Repair.Operation.Cancelled') `
            -Level WARN -Data @{ ExitCode = 2 }
        if (-not $NoPause) {
            Complete-WinlamaUIOperation `
                -Summary (Get-RepairText `
                    -Key 'Repair.Operation.Cancelled') `
                -Level SKIP -Command CIKIS
        }
        exit 2
    }
    $executionPolicy = Get-RepairExecutionPolicy `
        -SelectedMode $selectedMode
    $nonInteractive = $Preview -or ($NoPause -and $Mode -ne 'Menu')
    $installation = $localConfig.PSObject.Properties['Installation']
    $recordedRoot = if ($null -ne $installation -and $null -ne $installation.Value) {
        $recordedSource = $installation.Value.PSObject.Properties['Source']
        if ($null -ne $recordedSource) {
            [string]$recordedSource.Value
        }
    }
    $packageRoot = Select-RepairPackageRoot -RequestedRoot $SourceRoot `
        -RecordedRoot $recordedRoot `
        -AllowPathInput:($Mode -eq 'Menu' -and -not $Preview) `
        -NonInteractive:$nonInteractive
    $script:RepairMode = $selectedMode
    $script:RepairSource = $packageRoot
    $packageConfigPath = Resolve-RepairConfigPath -Root $packageRoot
    $packageConfig = Get-Content -LiteralPath $packageConfigPath `
        -Raw -Encoding UTF8 | ConvertFrom-RepairJson
    if (-not (Test-RepairManagedConfigurationSafe -Path $packageConfigPath)) {
        throw (Get-RepairText -Key 'Repair.Error.ConfigInvalid' `
            -Arguments @($packageConfigPath))
    }
    Assert-RepairCanonicalModelPaths -Config $packageConfig `
        -PackageRoot $packageRoot
    Assert-RepairModelCatalog -Config $packageConfig `
        -OfficialPrefixes $officialModelPrefixes `
        -AuditPrefixes $auditModelPrefixes `
        -Root $packageRoot
    $targets = Get-RepairTargets -SelectedMode $selectedMode `
        -SourceRoot $packageRoot -DestinationRoot $DestinationRoot `
        -Config $packageConfig -NonInteractive:$nonInteractive
    $script:RepairTarget = $targets.Primary
    Write-RepairStatus -Level INFO -Message (Get-RepairText `
        -Key 'Repair.Target.Selected' -Arguments @($targets.Primary))
    if ($targets.Disk) {
        Write-RepairStatus -Level INFO -Message (Get-RepairText `
            -Key 'Repair.Target.Selected' -Arguments @($targets.Disk))
    }
    if (-not $Apply -and -not $nonInteractive -and -not $WhatIfPreference) {
        $Apply = Confirm-RepairAction -Prompt (Get-RepairText `
            -Key 'Repair.Prompt.Apply')
    }
    Write-RepairLog -Event 'REPAIR_STARTED' `
        -Message (Get-RepairText `
            -Key 'Repair.Log.RepairStarted') `
        -Data @{ Mode = $selectedMode; Apply = [bool]$Apply;
            Source = $packageRoot }
    $modeKey = if ($Apply) {
        'Repair.Mode.Apply'
    }
    else {
        'Repair.Mode.Audit'
    }
    Write-RepairStatus -Level INFO -Message (Get-RepairText `
        -Key $modeKey)
    Write-RepairStatus -Level INFO -Message (Get-RepairText `
        -Key 'Repair.Source.Selected' -Arguments @($packageRoot))
    $targetEvent = if ($selectedMode -eq 'PublishPackage') {
        'Repair.Log.PublishTargetSelected'
    }
    else {
        'Repair.Log.InstalledTargetSelected'
    }
    Write-RepairLog -Event 'TARGET_SELECTED' -Message (Get-RepairText -Key $targetEvent) `
        -Data @{ Target = $targets.Primary; DiskTarget = $targets.Disk }
    $postValidationTarget = $targets.Primary
    $diskTarget = $targets.Disk
    if ($selectedMode -eq 'PublishPackage') {
        Invoke-RepairDiskScope -Source $packageRoot -Target $targets.Primary `
            -Config $packageConfig -Execute:$Apply
    }
    else {
        $installedRoot = $targets.Primary
        $installedConfig = Repair-RepairInstalledConfiguration `
            -PackageRoot $packageRoot `
            -InstalledRoot $installedRoot `
            -PackageConfig $packageConfig `
            -Execute:($Apply -and -not $WhatIfPreference)
        Write-RepairLog -Event 'TARGET_SELECTED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.InstalledTargetSelected') `
            -Data @{ Target = $installedRoot }
        Sync-RepairApplicationPayload -Source $packageRoot `
            -Target $installedRoot -Execute:$Apply
        Invoke-RepairInstalledComfyUIScope -SourceRoot $packageRoot `
            -InstalledRoot $installedRoot -Config $installedConfig `
            -ModelDirection $executionPolicy.ModelDirection `
            -AuditOnly:$executionPolicy.ModelAuditOnly
        Repair-OllamaPackages -PackageRoot $packageRoot `
            -Config $packageConfig `
            -Direction $executionPolicy.ModelDirection `
            -AuditOnly:$executionPolicy.ModelAuditOnly
        if ($Apply -and -not $WhatIfPreference) {
            if ($executionPolicy.InvokeInstaller) {
                Invoke-RepairInstaller -Root $packageRoot `
                    -InstalledRoot $installedRoot `
                    -Config $installedConfig
            }
        }
        if ($diskTarget) {
            Invoke-RepairDiskScope -Source $packageRoot -Target $diskTarget `
                -Config $packageConfig -Execute:$Apply
        }
    }
    if ($Apply -and -not $WhatIfPreference) {
        Invoke-RepairPostValidation -SourceRoot $packageRoot `
            -TargetRoot $postValidationTarget -Config $packageConfig `
            -SelectedMode $selectedMode `
            -ModelDirection $executionPolicy.ModelDirection `
            -DiskTarget $diskTarget
    }
    else {
        $script:ResolvedCount = 0
        $script:RemainingCount = $script:DifferentCount
    }
    $outcome = Get-RepairOutcome
    $summaryLevel = switch ($outcome.Name) {
        'Success' { 'SUCCESS' }
        'Incomplete' { 'WARN' }
        default { 'ERROR' }
    }
    $exitCode = Get-RepairExitCode -Outcome $outcome.Name
    Write-RepairStatus -Level $summaryLevel -Message (Get-RepairText `
        -Key 'Repair.Summary' `
        -Arguments @(
            $script:MatchedCount,
            $script:DifferentCount,
            $script:ResolvedCount,
            $outcome.Remaining,
            $script:CopiedCount,
            $script:DeletedCount,
            $script:SkippedItems.Count,
            $script:FailedItems.Count
        ))
    Write-RepairStatus -Level $summaryLevel -Message (Get-RepairText `
        -Key "Repair.Outcome.$($outcome.Name)")
    foreach ($item in $script:UnresolvedItems) {
        Write-RepairStatus -Level WARN -Message $item
    }
    foreach ($item in $script:SkippedItems) {
        Write-RepairStatus -Level SKIP -Message $item
    }
    foreach ($failure in $script:FailedItems) {
        Write-RepairStatus -Level ERROR -Message $failure
    }
    Write-RepairLog -Event 'REPAIR_COMPLETED' `
        -Message (Get-RepairText `
            -Key "Repair.Outcome.$($outcome.Name)") `
        -Level $(switch ($outcome.Name) {
            'Success' { 'INFO' }
            'Incomplete' { 'WARN' }
            default { 'ERROR' }
        }) `
        -Data @{ Matched = $script:MatchedCount;
            Different = $script:DifferentCount;
            Resolved = $script:ResolvedCount;
            Remaining = $outcome.Remaining;
            Copied = $script:CopiedCount;
            Deleted = $script:DeletedCount;
            Skipped = $script:SkippedItems.Count;
            Outcome = $outcome.Name;
            Failed = $script:FailedItems.Count }
}
catch {
    $exitCode = 1
    $message = $_.Exception.Message
    Add-RepairFailure -Message $message
    if (-not $ValidateOnly -and -not $Preview -and [string]::IsNullOrWhiteSpace(
        $script:RepairLogPath
    )) {
        Initialize-RepairFallbackDiagnostics
    }
    Write-RepairLog -Event 'REPAIR_FAILED' `
        -Message $message -Level ERROR `
        -Data (Get-RepairErrorData -ErrorRecord $_)
    Write-WinlamaUIError -Context (Get-RepairText `
        -Key 'Repair.Error.Failed' -Arguments @($message)) `
        -ErrorRecord $_
}
try {
    if ($GenerateReport) {
        Write-RepairReport
    }
}
catch {
    $reportError = $_.Exception.Message
    Add-RepairFailure -Message $reportError
    Write-RepairLog -Event 'REPORT_FAILED' `
        -Message $reportError -Level ERROR
    $exitCode = 1
    if (-not [string]::IsNullOrWhiteSpace(
        $script:RepairReportPath
    ) -and (Test-Path -LiteralPath `
        $script:RepairReportPath -PathType Leaf)) {
        try {
            Assert-RepairSafeTreePath `
                -Root $script:RepairReportsDirectory `
                -Path $script:RepairReportPath
            Remove-Item -LiteralPath $script:RepairReportPath `
                -Force -ErrorAction Stop
        }
        catch {
            Write-RepairStatus -Level WARN -Message (
                Get-RepairText `
                    -Key 'Repair.Warning.ReportVerificationFailed' `
                    -Arguments @($_.Exception.Message)
            )
        }
    }
    Write-RepairStatus -Level WARN -Message (Get-RepairText `
        -Key 'Repair.Report.Failed' `
        -Arguments @($reportError))
}
if (-not $NoPause -and -not $ValidateOnly -and -not $Preview) {
    $completion = if ($exitCode -eq 0) {
        [pscustomobject]@{
            Key = 'Repair.Operation.Completed'
            Level = 'SUCCESS'
        }
    }
    elseif ($exitCode -eq 3) {
        [pscustomobject]@{
            Key = 'Repair.Operation.Incomplete'
            Level = 'WARN'
        }
    }
    else {
        [pscustomobject]@{
            Key = 'Repair.Operation.Failed'
            Level = 'ERROR'
        }
    }
    Complete-WinlamaUIOperation `
        -Summary (Get-RepairText -Key $completion.Key) `
        -Level $completion.Level `
        -Command CIKIS
}
exit $exitCode