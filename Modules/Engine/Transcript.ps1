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