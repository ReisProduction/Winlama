Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WinlamaConsoleWidth = 100
function Test-WinlamaConsoleBufferClear {
    [CmdletBinding()]
    param(
        [switch]$Requested,
        [bool]$OutputRedirected = [Console]::IsOutputRedirected
    )
    return [bool]$Requested -and -not $OutputRedirected
}
function Initialize-WinlamaConsole {
    [CmdletBinding()]
    param([switch]$ClearBuffer)
    try {
        $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
        $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::White
    }
    catch {
        Write-Verbose (Get-WinlamaUIString `
            -Key 'Common.Verbose.RawConsoleColorsUnavailable' `
            -Fallback 'Ham konsol renkleri ayarlanamadi: {0}' `
            -Arguments @($_.Exception.Message))
    }
    try {
        [Console]::BackgroundColor = [ConsoleColor]::Black
        [Console]::ForegroundColor = [ConsoleColor]::White
    }
    catch {
        Write-Verbose (Get-WinlamaUIString `
            -Key 'Common.Verbose.ConsoleColorsUnavailable' `
            -Fallback 'Konsol renkleri ayarlanamadi: {0}' `
            -Arguments @($_.Exception.Message))
    }
    try {
        if (Test-WinlamaConsoleBufferClear `
            -Requested:$ClearBuffer) {
            Clear-Host
        }
    }
    catch {
        Write-Verbose (Get-WinlamaUIString `
            -Key 'Common.Verbose.ConsoleRefreshUnavailable' `
            -Fallback 'Konsol arka plani yenilenemedi: {0}' `
            -Arguments @($_.Exception.Message))
    }
}
function Get-WinlamaConsoleWidth {
    return $script:WinlamaConsoleWidth
}
function Get-WinlamaUIString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Fallback,
        [object[]]$Arguments = @()
    )
    $value = $null
    $command = Get-Command Get-LocalizedText `
        -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try {
            $candidate = [string](& $command -Key $Key `
                -Arguments $Arguments)
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                $candidate -cne $Key) {
                $value = $candidate
            }
        }
        catch {
            Write-Verbose ('UI metni yerellestirilemedi: {0} | {1}' -f `
                $Key, $_.Exception.Message)
        }
    }
    if ($null -ne $value) {
        return $value
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
function Format-WinlamaUIRule {
    [CmdletBinding()]
    param([ValidateSet('-', '=')][string]$Character = '-')
    return $Character * $script:WinlamaConsoleWidth
}
function Format-WinlamaUILine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    $width = $script:WinlamaConsoleWidth - 4
    $lines = [Collections.Generic.List[string]]::new()
    $logicalLines = [regex]::Split($Text, '\r\n|\n|\r')
    foreach ($logicalLine in $logicalLines) {
        $remaining = $logicalLine.TrimStart()
        do {
            $length = [Math]::Min($width, $remaining.Length)
            if ($remaining.Length -gt $width) {
                $breakAt = $remaining.LastIndexOf(' ', $width - 1, $width)
                if ($breakAt -gt 20) {
                    $length = $breakAt
                }
            }
            $part = $remaining.Substring(0, $length)
            $lines.Add(('| {0} |' -f $part.PadRight($width)))
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
function Format-WinlamaUICenteredField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [ValidateRange(1, 96)]
        [int]$Width
    )
    if ($Text.Length -gt $Width) {
        throw "UI alani genisligi asildi: $Text"
    }
    $left = [Math]::Floor(($Width - $Text.Length) / 2)
    return ((' ' * $left) + $Text).PadRight($Width)
}
function New-WinlamaUITableColumn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [ValidateRange(1, 92)]
        [int]$Width,
        [ValidateSet('Left', 'Center', 'Right')]
        [string]$Alignment = 'Left',
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    $column = [pscustomobject]@{
        Text = $Text
        Width = $Width
        Alignment = $Alignment
        Color = $Color
    }
    $column.PSObject.TypeNames.Insert(0, 'Winlama.UI.TableColumn')
    return $column
}
function Split-WinlamaUITableCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [ValidateRange(1, 92)]
        [int]$Width,
        [Parameter(Mandatory)]
        [ValidateSet('Left', 'Center', 'Right')]
        [string]$Alignment
    )
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($logicalLine in [regex]::Split($Text, '\r\n|\n|\r')) {
        $remaining = $logicalLine.TrimStart()
        if ($remaining.Length -eq 0) {
            $segments.Add(' ' * $Width)
            continue
        }
        while ($remaining.Length -gt 0) {
            $length = [Math]::Min($Width, $remaining.Length)
            if ($remaining.Length -gt $Width) {
                $breakAt = $remaining.LastIndexOf(
                    ' ', $Width - 1, $Width
                )
                if ($breakAt -gt 0) {
                    $length = $breakAt
                }
            }
            $part = $remaining.Substring(0, $length)
            $field = switch ($Alignment) {
                'Center' {
                    Format-WinlamaUICenteredField `
                        -Text $part -Width $Width
                }
                'Right' { $part.PadLeft($Width) }
                default { $part.PadRight($Width) }
            }
            $segments.Add($field)
            if ($remaining.Length -le $length) {
                $remaining = ''
            }
            else {
                $remaining = $remaining.Substring($length).TrimStart()
            }
        }
    }
    return $segments.ToArray()
}
function Format-WinlamaUITableRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Columns
    )
    $totalWidth = 1 + (3 * $Columns.Count)
    $cellLines = [Collections.Generic.List[object]]::new()
    $colors = [Collections.Generic.List[ConsoleColor]]::new()
    $lineCount = 0
    foreach ($column in $Columns) {
        if ($null -eq $column -or
            -not $column.PSObject.TypeNames.Contains(
                'Winlama.UI.TableColumn'
            )) {
            throw 'Winlama UI tablo sutunu tipi gecersiz.'
        }
        $totalWidth += $column.Width
        $lines = @(Split-WinlamaUITableCell `
            -Text $column.Text -Width $column.Width `
            -Alignment $column.Alignment)
        $cellLines.Add($lines)
        $colors.Add([ConsoleColor]$column.Color)
        $lineCount = [Math]::Max($lineCount, $lines.Count)
    }
    if ($totalWidth -ne $script:WinlamaConsoleWidth) {
        throw "Winlama UI tablo genisligi gecersiz: $totalWidth"
    }
    $rows = [Collections.Generic.List[object]]::new()
    for ($lineIndex = 0; $lineIndex -lt $lineCount; $lineIndex++) {
        $cells = [Collections.Generic.List[string]]::new()
        for ($columnIndex = 0; $columnIndex -lt $Columns.Count;
            $columnIndex++) {
            $lines = $cellLines[$columnIndex]
            $cell = if ($lineIndex -lt $lines.Count) {
                [string]$lines[$lineIndex]
            }
            else {
                ' ' * $Columns[$columnIndex].Width
            }
            $cells.Add($cell)
        }
        $row = [pscustomobject]@{
            Text = '| ' + ($cells.ToArray() -join ' | ') + ' |'
            Cells = $cells.ToArray()
            Colors = $colors.ToArray()
        }
        $row.PSObject.TypeNames.Insert(0, 'Winlama.UI.TableRow')
        $rows.Add($row)
    }
    return $rows.ToArray()
}
function Write-WinlamaUITableRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Columns
    )
    foreach ($row in @(Format-WinlamaUITableRow -Columns $Columns)) {
        Write-Host '| ' -NoNewline -ForegroundColor Cyan `
            -BackgroundColor Black
        for ($index = 0; $index -lt $row.Cells.Count; $index++) {
            Write-Host $row.Cells[$index] -NoNewline `
                -ForegroundColor $row.Colors[$index] `
                -BackgroundColor Black
            if ($index -lt ($row.Cells.Count - 1)) {
                Write-Host ' | ' -NoNewline -ForegroundColor Cyan `
                    -BackgroundColor Black
            }
        }
        Write-Host ' |' -ForegroundColor Cyan `
            -BackgroundColor Black
    }
}
function Format-WinlamaUIStatusLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )
    $statusWidth = @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    ) | ForEach-Object {
        (Get-WinlamaUIStatusStyle -Level $_).Label.Length
    } | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    $messageWidth = $script:WinlamaConsoleWidth - $statusWidth - 7
    $lines = [Collections.Generic.List[string]]::new()
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
            $status = if ($first) {
                Format-WinlamaUICenteredField -Text $Label `
                    -Width $statusWidth
            }
            else {
                ' ' * $statusWidth
            }
            $lines.Add(('| {0} | {1} |' -f `
                $status, $part.PadRight($messageWidth)))
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
function Write-WinlamaUIRule {
    [CmdletBinding()]
    param(
        [ValidateSet('-', '=')][string]$Character = '-',
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    Write-Host (Format-WinlamaUIRule -Character $Character) `
        -ForegroundColor $Color -BackgroundColor Black
}
function Write-WinlamaUILine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    foreach ($line in @(Format-WinlamaUILine -Text $Text)) {
        Write-Host $line -ForegroundColor $Color -BackgroundColor Black
    }
}
function Get-WinlamaUIStatusStyle {
    [CmdletBinding()]
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
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Info' -Fallback 'BILGI'
                Color = 'Cyan'
            }
        }
        'STEP' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Step' -Fallback 'ADIM'
                Color = 'Blue'
            }
        }
        'SUCCESS' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Ok' -Fallback 'TAMAM'
                Color = 'Green'
            }
        }
        'WARN' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Warning' -Fallback 'UYARI'
                Color = 'Yellow'
            }
        }
        'ERROR' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Error' -Fallback 'HATA'
                Color = 'Red'
            }
        }
        'DETAIL' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Detail' -Fallback 'DETAY'
                Color = 'Gray'
            }
        }
        'SKIP' {
            [pscustomobject]@{
                Label = Get-WinlamaUIString `
                    -Key 'Common.Level.Skip' -Fallback 'ATLA'
                Color = 'Magenta'
            }
        }
    }
    return $style
}
function Get-WinlamaUIStatusMessageColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level
    )
    if ($Level -ceq 'DETAIL') {
        return [ConsoleColor]::Gray
    }
    return [ConsoleColor]::White
}
function Write-WinlamaUIConsoleSegment {
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
function Write-WinlamaUIStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL',
            'SKIP'
        )]
        [string]$Level,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [scriptblock]$SegmentWriter
    )
    $style = Get-WinlamaUIStatusStyle -Level $Level
    $statusWidth = @(
        'INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR', 'DETAIL', 'SKIP'
    ) | ForEach-Object {
        (Get-WinlamaUIStatusStyle -Level $_).Label.Length
    } | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    $messageWidth = $script:WinlamaConsoleWidth - $statusWidth - 7
    $messageColor = Get-WinlamaUIStatusMessageColor -Level $Level
    foreach ($line in @(Format-WinlamaUIStatusLines `
        -Label $style.Label -Message $Message)) {
        Write-WinlamaUIConsoleSegment -Text '| ' -Color Gray `
            -NoNewline -SegmentWriter $SegmentWriter
        Write-WinlamaUIConsoleSegment `
            -Text $line.Substring(2, $statusWidth) `
            -Color $style.Color -NoNewline `
            -SegmentWriter $SegmentWriter
        Write-WinlamaUIConsoleSegment -Text ' | ' -Color Gray `
            -NoNewline -SegmentWriter $SegmentWriter
        Write-WinlamaUIConsoleSegment `
            -Text $line.Substring($statusWidth + 5, $messageWidth) `
            -Color $messageColor -NoNewline `
            -SegmentWriter $SegmentWriter
        Write-WinlamaUIConsoleSegment -Text ' |' -Color Gray `
            -SegmentWriter $SegmentWriter
    }
}
function Get-WinlamaUISelectionLabel {
    return Get-WinlamaUIString `
        -Key 'Common.Prompt.Selection' `
        -Fallback ('Se{0}iminiz' -f [char]0x00E7)
}
function Get-WinlamaUIInputDisplay {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value = ''
    )
    $prefix = Get-WinlamaUISelectionLabel
    $capacity = 96 - ($prefix.Length + 2)
    if ($capacity -lt 4) {
        $capacity = 4
    }
    if ($Value.Length -le $capacity) {
        return $Value
    }
    return '...' + $Value.Substring(
        $Value.Length - ($capacity - 3)
    )
}
function Format-WinlamaUIInputLine {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value = ''
    )
    $display = Get-WinlamaUIInputDisplay -Value $Value
    $selection = Get-WinlamaUISelectionLabel
    $line = @(Format-WinlamaUILine `
        -Text ("${selection}: $display"))
    return $line[0]
}
function Write-WinlamaUIInputLine {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value = ''
    )
    Write-Host (Format-WinlamaUIInputLine -Value $Value) `
        -ForegroundColor White -BackgroundColor Black
}
function Read-WinlamaInteractiveInput {
    [CmdletBinding()]
    param()
    $row = [Console]::CursorTop
    $buffer = [Text.StringBuilder]::new()
    while ($true) {
        $value = $buffer.ToString()
        $display = Get-WinlamaUIInputDisplay -Value $value
        $selection = Get-WinlamaUISelectionLabel
        [Console]::SetCursorPosition(0, $row)
        $Host.UI.Write(
            [ConsoleColor]::White,
            [ConsoleColor]::Black,
            (Format-WinlamaUIInputLine -Value $value)
        )
        [Console]::SetCursorPosition(
            [Math]::Min(
                98,
                4 + $selection.Length + $display.Length
            ),
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
    [Console]::SetCursorPosition(0, $row)
    $Host.UI.WriteLine(
        [ConsoleColor]::White,
        [ConsoleColor]::Black,
        (Format-WinlamaUIInputLine -Value $buffer.ToString())
    )
    return $buffer.ToString()
}
function Format-WinlamaUIInputPrompt {
    [CmdletBinding()]
    param([string]$Label = '')
    return Format-WinlamaUIInputLine
}
function Read-WinlamaUIInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Label = '',
        [string]$Hint = '',
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    $selectionPrompt = Get-WinlamaUISelectionLabel
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = $selectionPrompt
    }
    $hasPrompt = -not [string]::IsNullOrWhiteSpace($Prompt) -and
        $Prompt.Trim() -ine $Label.Trim() -and
        $Prompt.Trim() -ine $selectionPrompt.Trim()
    $hasHint = -not [string]::IsNullOrWhiteSpace($Hint)
    if (-not $NoLeadingRule) {
        Write-WinlamaUIRule
    }
    if ($hasPrompt) {
        Write-WinlamaUIStatus -Level INFO -Message $Prompt
    }
    if ($hasHint) {
        Write-WinlamaUIStatus -Level DETAIL -Message $Hint
    }
    if ($hasPrompt -or $hasHint) {
        Write-WinlamaUIRule
    }
    $value = ''
    if ($null -ne $InputReader) {
        $value = [string](& $InputReader $Label)
        Write-WinlamaUIInputLine -Value $value
    }
    elseif ([Console]::IsInputRedirected) {
        $readValue = $Host.UI.ReadLine()
        if ($null -eq $readValue) {
            throw [IO.EndOfStreamException]::new(
                'Standart girdi kapali; zorunlu komut okunamadi.'
            )
        }
        $value = [string]$readValue
        Write-WinlamaUIInputLine -Value $value
    }
    else {
        try {
            $value = Read-WinlamaInteractiveInput
        }
        catch {
            $readValue = $Host.UI.ReadLine()
            if ($null -eq $readValue) {
                throw [IO.EndOfStreamException]::new(
                    'Standart girdi kapali; zorunlu komut okunamadi.'
                )
            }
            $value = [string]$readValue
            Write-WinlamaUIInputLine -Value $value
        }
    }
    Write-WinlamaUIRule
    return $value
}
function Confirm-WinlamaUIAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    while ($true) {
        $answer = Read-WinlamaUIInput -Prompt $Prompt `
            -Label (Get-WinlamaUISelectionLabel) `
            -Hint (Get-WinlamaUIString `
                -Key 'Common.Prompt.ExactYesNo' `
                -Fallback 'Yalniz tam olarak EVET veya HAYIR yazin.') `
            -InputReader $InputReader `
            -NoLeadingRule:$NoLeadingRule
        if ($answer -ceq 'EVET') {
            return $true
        }
        if ($answer -ceq 'HAYIR') {
            return $false
        }
        Write-WinlamaUIStatus -Level WARN `
            -Message (Get-WinlamaUIString `
                -Key 'Common.Confirmation.Invalid' `
                -Fallback 'Bos veya gecersiz onay kabul edilmedi.')
    }
}
function Wait-WinlamaUICommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('CIKIS', 'DEVAM')]
        [string]$Command,
        [scriptblock]$InputReader,
        [switch]$NoLeadingRule
    )
    while ($true) {
        $value = Read-WinlamaUIInput -Prompt $Prompt `
            -Label (Get-WinlamaUISelectionLabel) `
            -Hint (Get-WinlamaUIString `
                -Key 'Common.Prompt.ExactCommand' `
                -Fallback 'Yalniz tam olarak {0} yazin.' `
                -Arguments @($Command)) `
            -InputReader $InputReader `
            -NoLeadingRule:$NoLeadingRule
        if ($value -ceq $Command) {
            return
        }
        Write-WinlamaUIStatus -Level WARN `
            -Message (Get-WinlamaUIString `
                -Key 'Common.Command.Invalid' `
                -Fallback 'Bos veya gecersiz komut kabul edilmedi.')
    }
}
function Complete-WinlamaUIOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Summary,
        [ValidateSet('SUCCESS', 'WARN', 'ERROR', 'SKIP')]
        [string]$Level = 'SUCCESS',
        [ValidateSet('CIKIS', 'DEVAM')]
        [string]$Command = 'CIKIS',
        [scriptblock]$InputReader
    )
    Write-WinlamaUIRule -Character '=' -Color Cyan
    Write-WinlamaUILine -Text (Get-WinlamaUIString `
        -Key 'Common.Operation.Summary' `
        -Fallback 'ISLEM OZETI') -Color Cyan
    Write-WinlamaUIStatus -Level $Level -Message $Summary
    Write-WinlamaUIRule -Character '=' -Color Cyan
    $prompt = if ($Command -ceq 'DEVAM') {
        Get-WinlamaUIString -Key 'Common.Prompt.ReturnToMenu' `
            -Fallback 'Ana menuye donmek icin DEVAM yazin.'
    }
    else {
        Get-WinlamaUIString -Key 'Common.Prompt.Close' `
            -Fallback 'Oturumu kapatmak icin CIKIS yazin.'
    }
    Wait-WinlamaUICommand -Prompt $prompt -Command $Command `
        -InputReader $InputReader
}
function Write-WinlamaUIError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord
    )
    Write-WinlamaUIRule -Character '=' -Color Red
    Write-WinlamaUIStatus -Level ERROR -Message $Context
    Write-WinlamaUIStatus -Level ERROR `
        -Message $ErrorRecord.Exception.Message
    Write-WinlamaUIStatus -Level DETAIL `
        -Message (Get-WinlamaUIString `
            -Key 'Common.Error.Type' -Fallback 'Tur: {0}' `
            -Arguments @($ErrorRecord.Exception.GetType().FullName))
    if (-not [string]::IsNullOrWhiteSpace(
        $ErrorRecord.InvocationInfo.PositionMessage
    )) {
        Write-WinlamaUIStatus -Level DETAIL `
            -Message $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    Write-WinlamaUIRule -Character '=' -Color Red
}
function Assert-WinlamaUIInputFormatter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Formatter)
    $empty = @(& $Formatter '')
    $long = @(& $Formatter ('0123456789' * 12))
    $selection = Get-WinlamaUISelectionLabel
    if ($empty.Count -ne 1 -or $long.Count -ne 1 -or
        ([string]$empty[0]).Length -ne $script:WinlamaConsoleWidth -or
        ([string]$long[0]).Length -ne $script:WinlamaConsoleWidth -or
        -not ([string]$empty[0]).StartsWith(
            ('| {0}: ' -f $selection)
        ) -or
        -not ([string]$empty[0]).EndsWith(' |') -or
        -not ([string]$long[0]).StartsWith(
            ('| {0}: ...' -f $selection)
        ) -or
        -not ([string]$long[0]).EndsWith(' |')) {
        throw 'Winlama UI bootstrap secim geometrisi gecersiz.'
    }
    return $true
}
function Assert-WinlamaUIStandard {
    [CmdletBinding()]
    param()
    $width = Get-WinlamaConsoleWidth
    if ($width -ne 100) {
        throw "Winlama UI genisligi gecersiz: $width"
    }
    if ((Test-WinlamaConsoleBufferClear -OutputRedirected $false) -or
        -not (Test-WinlamaConsoleBufferClear -Requested `
            -OutputRedirected $false) -or
        (Test-WinlamaConsoleBufferClear -Requested `
            -OutputRedirected $true)) {
        throw 'Winlama UI konsol temizleme sozlesmesi gecersiz.'
    }
    foreach ($character in @('-', '=')) {
        $rule = Format-WinlamaUIRule -Character $character
        if ($rule.Length -ne $width -or
            $rule -ne ($character * $width)) {
            throw "Winlama UI kural cizgisi gecersiz: $character"
        }
    }
    $sample = @(Format-WinlamaUILine -Text ('X' * 220))
    if ($sample.Count -ne 3) {
        throw 'Winlama UI satir kaydirma sayisi gecersiz.'
    }
    foreach ($line in $sample) {
        if ($line.Length -ne $width -or
            -not $line.StartsWith('| ') -or
            -not $line.EndsWith(' |')) {
            throw 'Winlama UI cerceve geometrisi gecersiz.'
        }
    }
    $multiline = @(Format-WinlamaUILine `
        -Text "Birinci`r`nIkinci`nUcuncu")
    if ($multiline.Count -ne 3) {
        throw 'Winlama UI cok satirli metin sayisi gecersiz.'
    }
    foreach ($line in $multiline) {
        if ($line.Length -ne $width -or
            -not $line.StartsWith('| ') -or
            -not $line.EndsWith(' |') -or
            $line -match '[\r\n]') {
            throw 'Winlama UI cok satirli metin geometrisi gecersiz.'
        }
    }
    $indented = @(Format-WinlamaUILine -Text '  [7] Kaldirma')
    if ($indented.Count -ne 1 -or
        -not $indented[0].StartsWith('| [7]') -or
        $indented[0] -match '^\|\s{2,}\S') {
        throw 'Winlama UI sol bosluk geometrisi gecersiz.'
    }
    $centeredLongest = Format-WinlamaUICenteredField `
        -Text 'BILGI' -Width 5
    $centeredOdd = Format-WinlamaUICenteredField -Text 'KISA' -Width 5
    $centeredEven = Format-WinlamaUICenteredField -Text 'KIS' -Width 5
    $statusLines = @(Format-WinlamaUIStatusLines `
        -Label 'BILGI' -Message ('X' * 180))
    if ($centeredLongest -cne 'BILGI' -or
        $centeredOdd -cne 'KISA ' -or
        $centeredEven -cne ' KIS ' -or
        $statusLines.Count -ne 3 -or
        $statusLines[0].Length -ne $width -or
        -not $statusLines[0].StartsWith('| BILGI | ') -or
            -not $statusLines[1].StartsWith('|       | ')) {
        throw 'Winlama UI ortali durum geometrisi gecersiz.'
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
    $fixtureLine = @(Format-WinlamaUIStatusLines `
        -Label 'BILGI' -Message 'Fixture')[0]
    Write-WinlamaUIStatus -Level INFO -Message Fixture `
        -SegmentWriter $segmentWriter
    $renderedText = @($segments | ForEach-Object {
        $_.Text
    }) -join ''
    $segmentContract = $segments.Count -eq 5 -and
        $renderedText -ceq $fixtureLine -and
        $segments[0].Color -eq [ConsoleColor]::Gray -and
        $segments[1].Color -eq [ConsoleColor]::Cyan -and
        $segments[2].Color -eq [ConsoleColor]::Gray -and
        $segments[3].Color -eq [ConsoleColor]::White -and
        $segments[4].Color -eq [ConsoleColor]::Gray -and
        @($segments | Where-Object {
            $_.BackgroundColor -ne [ConsoleColor]::Black
        }).Count -eq 0 -and
        @($segments[0..3] | Where-Object {
            -not $_.NoNewline
        }).Count -eq 0 -and -not $segments[4].NoNewline
    $segments.Clear()
    Write-WinlamaUIStatus -Level DETAIL -Message Fixture `
        -SegmentWriter $segmentWriter
    $detailMessageContract = $segments.Count -eq 5 -and
        $segments[3].Color -eq [ConsoleColor]::Gray
    if (-not $segmentContract -or -not $detailMessageContract) {
        throw 'Winlama UI parcali renk sozlesmesi gecersiz.'
    }
    $tableColumns = @(
        New-WinlamaUITableColumn -Text 'YEREL' -Width 5 `
            -Alignment Center -Color Green
        New-WinlamaUITableColumn -Text 'ornek-model' -Width 32 `
            -Color Cyan
        New-WinlamaUITableColumn `
            -Text ('C:\Winlama\Models\' +
                ('cok-uzun-model-klasoru\' * 6) +
                'model.safetensors') `
            -Width 53 -Color Gray
    )
    $tableRows = @(Format-WinlamaUITableRow -Columns $tableColumns)
    if ($tableRows.Count -lt 2 -or
        $tableRows[0].Cells[0] -cne 'YEREL' -or
        -not [string]::IsNullOrWhiteSpace($tableRows[1].Cells[0]) -or
        -not [string]::IsNullOrWhiteSpace($tableRows[1].Cells[1])) {
        throw 'Winlama UI tablo devam satiri geometrisi gecersiz.'
    }
    foreach ($row in $tableRows) {
        if ($row.PSObject.TypeNames[0] -cne 'Winlama.UI.TableRow' -or
            $row.Text.Length -ne $width -or
            $row.Text[0] -cne '|' -or
            $row.Text[8] -cne '|' -or
            $row.Text[43] -cne '|' -or
            $row.Text[99] -cne '|' -or
            $row.Cells[0].Length -ne 5 -or
            $row.Cells[1].Length -ne 32 -or
            $row.Cells[2].Length -ne 53) {
            throw 'Winlama UI tablo kolon geometrisi gecersiz.'
        }
    }
    $selection = Get-WinlamaUISelectionLabel
    $inputLine = Format-WinlamaUIInputPrompt -Label $selection
    if ($inputLine.Length -ne $width -or
        -not $inputLine.StartsWith(('| {0}: ' -f $selection)) -or
        -not $inputLine.EndsWith(' |') -or
        (Format-WinlamaUIInputPrompt -Label '[EVET]') `
            -cne $inputLine) {
        throw 'Winlama UI secim istemi geometrisi gecersiz.'
    }
    $longValue = '0123456789' * 12
    $longInputLine = Format-WinlamaUIInputLine -Value $longValue
    if ($longInputLine.Length -ne $width -or
        -not $longInputLine.StartsWith(
            ('| {0}: ...' -f $selection)
        ) -or
        -not $longInputLine.EndsWith(' |') -or
        -not $longInputLine.Contains($longValue.Substring(38)) -or
        $longInputLine -match '[\r\n]') {
        throw 'Winlama UI uzun secim istemi geometrisi gecersiz.'
    }
    $menuInputRender = @(& {
        Write-WinlamaUIRule
        $null = Read-WinlamaUIInput -Prompt $selection `
            -Label $selection -NoLeadingRule `
            -InputReader { '0' }
    } 6>&1 | ForEach-Object { [string]$_ })
    $duplicateRules = 0
    for ($index = 1; $index -lt $menuInputRender.Count; $index++) {
        if ($menuInputRender[$index] -ceq $menuInputRender[$index - 1] -and
            $menuInputRender[$index] -match '^[-=]{100}$') {
            $duplicateRules++
        }
    }
    if ($duplicateRules -ne 0) {
        throw 'Winlama UI ard arda yinelenen cizgi sozlesmesi gecersiz.'
    }
    $yesQueue = [Collections.Generic.Queue[string]]::new()
    $yesQueue.Enqueue('')
    $yesQueue.Enqueue('E')
    $yesQueue.Enqueue('evet')
    $yesQueue.Enqueue(' EVET ')
    $yesQueue.Enqueue('EVET')
    $confirmed = Confirm-WinlamaUIAction `
        -Prompt 'Dogrulama onayi.' `
        -InputReader { $yesQueue.Dequeue() }.GetNewClosure()
    $noQueue = [Collections.Generic.Queue[string]]::new()
    $noQueue.Enqueue('')
    $noQueue.Enqueue('H')
    $noQueue.Enqueue('hayir')
    $noQueue.Enqueue(' HAYIR ')
    $noQueue.Enqueue('HAYIR')
    $rejected = Confirm-WinlamaUIAction `
        -Prompt 'Dogrulama reddi.' `
        -InputReader { $noQueue.Dequeue() }.GetNewClosure() `
        -NoLeadingRule
    $exitQueue = [Collections.Generic.Queue[string]]::new()
    $exitQueue.Enqueue('')
    $exitQueue.Enqueue('Enter')
    $exitQueue.Enqueue('cikis')
    $exitQueue.Enqueue(' CIKIS ')
    $exitQueue.Enqueue('CIKIS')
    Wait-WinlamaUICommand -Prompt 'Dogrulama kapanisi.' `
        -Command CIKIS `
        -InputReader { $exitQueue.Dequeue() }.GetNewClosure() `
        -NoLeadingRule
    $continueQueue = [Collections.Generic.Queue[string]]::new()
    $continueQueue.Enqueue('')
    $continueQueue.Enqueue('Enter')
    $continueQueue.Enqueue('devam')
    $continueQueue.Enqueue(' DEVAM ')
    $continueQueue.Enqueue('DEVAM')
    Complete-WinlamaUIOperation `
        -Summary 'Dogrulama islemi tamamlandi.' `
        -Level SUCCESS -Command DEVAM `
        -InputReader { $continueQueue.Dequeue() }.GetNewClosure()
    if (-not $confirmed -or $rejected) {
        throw 'Winlama UI kesin onay sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_UI_OK:ConsoleUI.ExactTokens'
    $expectedStyles = [ordered]@{
        INFO = 'BILGI|Cyan'
        STEP = 'ADIM|Blue'
        SUCCESS = 'TAMAM|Green'
        WARN = 'UYARI|Yellow'
        ERROR = 'HATA|Red'
        DETAIL = 'DETAY|Gray'
        SKIP = 'ATLA|Magenta'
    }
    foreach ($level in $expectedStyles.Keys) {
        $style = Get-WinlamaUIStatusStyle -Level $level
        if (('{0}|{1}' -f $style.Label, $style.Color) -cne `
            $expectedStyles[$level]) {
            throw "Winlama UI renk sozlesmesi gecersiz: $level"
        }
    }
    $styleColors = @($expectedStyles.Keys | ForEach-Object {
        [string](Get-WinlamaUIStatusStyle -Level $_).Color
    })
    if (@($styleColors | Sort-Object -Unique).Count -ne
        $styleColors.Count -or 'Black' -in $styleColors) {
        throw 'Winlama UI yuksek kontrast renk sozlesmesi gecersiz.'
    }
    $inputSource = (Get-Command Read-WinlamaUIInput `
        -ErrorAction Stop).Definition
    if ($inputSource.IndexOf(
            '[Console]::IsOutputRedirected',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'Winlama UI cikti hatti girdiyi gizleyemez.'
    }
    Write-Verbose 'WINLAMA_UI_OK:ConsoleUI.OutputPipelineInput'
    Write-Verbose 'WINLAMA_UI_OK:ConsoleUI.PreserveChildBuffer'
    Write-Verbose 'WINLAMA_UI_OK:ConsoleUI.SegmentedBlackBackground'
    Write-Verbose 'WINLAMA_UI_OK:ConsoleUI.DistinctStatusPalette'
    return $true
}
Initialize-WinlamaConsole
Export-ModuleMember -Function @(
    'Initialize-WinlamaConsole',
    'Get-WinlamaConsoleWidth',
    'Get-WinlamaUIString',
    'Format-WinlamaUIRule',
    'Format-WinlamaUILine',
    'Format-WinlamaUICenteredField',
    'New-WinlamaUITableColumn',
    'Format-WinlamaUITableRow',
    'Write-WinlamaUITableRow',
    'Format-WinlamaUIStatusLines',
    'Get-WinlamaUIStatusStyle',
    'Get-WinlamaUISelectionLabel',
    'Write-WinlamaUIRule',
    'Write-WinlamaUILine',
    'Write-WinlamaUIStatus',
    'Format-WinlamaUIInputLine',
    'Write-WinlamaUIInputLine',
    'Read-WinlamaInteractiveInput',
    'Format-WinlamaUIInputPrompt',
    'Read-WinlamaUIInput',
    'Confirm-WinlamaUIAction',
    'Wait-WinlamaUICommand',
    'Complete-WinlamaUIOperation',
    'Write-WinlamaUIError',
    'Assert-WinlamaUIInputFormatter',
    'Assert-WinlamaUIStandard'
)