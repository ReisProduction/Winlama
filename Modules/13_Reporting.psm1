Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertTo-HtmlSafeText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}
function ConvertTo-CheckTable {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Checks
    )
    if ($null -eq $Checks) {
        return Get-LocalizedText -Key 'Reporting.Empty'
    }
    $rows = foreach ($property in $Checks.PSObject.Properties) {
        $class = if ($property.Value) { 'ok' } else { 'bad' }
        $text = if ($property.Value) {
            Get-LocalizedText -Key 'Common.Status.Ready'
        }
        else {
            Get-LocalizedText -Key 'Common.Level.Error'
        }
        '<tr><td>{0}</td><td class="{1}">{2}</td></tr>' -f `
            (ConvertTo-HtmlSafeText (Get-LocalizedText `
                -Key "Reporting.Check.$($property.Name)")), $class, $text
    }
    return '<table><tbody>{0}</tbody></table>' -f ($rows -join '')
}
function Test-ReportingComponentAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('Ollama', 'OpenWebUI', 'Voice', 'ComfyUI')]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$ProbeInvoker
    )
    $section = $Context.Config.PSObject.Properties[$Name]
    if ($null -eq $section -or -not [bool]$section.Value.Enabled) {
        return $false
    }
    if (Test-AiRuntimeComponentDegraded `
        -Context $Context -Name $Name) {
        return $false
    }
    try {
        return [bool](& $ProbeInvoker $Name $Context)
    }
    catch {
        Write-Verbose ('Rapor servis saglik denetimi basarisiz: {0} | {1}' `
            -f $Name, $_.Exception.Message)
        return $false
    }
}
function Get-ReportingEndpointProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [scriptblock]$ProbeInvoker = {
            param([string]$Name, [pscustomobject]$RuntimeContext)
            switch ($Name) {
                'Ollama' {
                    return Test-OllamaApiReady -Context $RuntimeContext
                }
                'OpenWebUI' {
                    return Test-OpenWebUIReady -Context $RuntimeContext
                }
                'Voice' {
                    return Test-WinlamaTtsReady -Context $RuntimeContext
                }
                'ComfyUI' {
                    return Test-ComfyUIReady -Context $RuntimeContext
                }
            }
            return $false
        }
    )
    $available = [ordered]@{}
    foreach ($name in @('Ollama', 'OpenWebUI', 'Voice', 'ComfyUI')) {
        $available[$name] = Test-ReportingComponentAvailable `
            -Context $Context -Name $name -ProbeInvoker $ProbeInvoker
    }
    if (-not ($available.Values -contains $true)) {
        return
    }
    $uris = Get-WinlamaServiceUris -Config $Context.Config
    $endpoints = [Collections.Generic.List[object]]::new()
    $addEndpoint = {
        param([string]$LabelKey, [string]$Uri)
        if (-not [string]::IsNullOrWhiteSpace($Uri)) {
            $endpoints.Add([pscustomobject][ordered]@{
                LabelKey = $LabelKey
                Uri = $Uri
            })
        }
    }
    if ($available.Ollama) {
        & $addEndpoint 'Reporting.Endpoint.OllamaLocal' `
            $uris.OllamaLocal
        & $addEndpoint 'Reporting.Endpoint.OllamaLan' $uris.OllamaLan
    }
    if ($available.OpenWebUI) {
        & $addEndpoint 'Reporting.Endpoint.WebUILocal' `
            $uris.OpenWebUILocal
        & $addEndpoint 'Reporting.Endpoint.WebUITemporary' `
            $uris.OpenWebUITemporary
        & $addEndpoint 'Reporting.Endpoint.WebUILan' `
            $uris.OpenWebUILan
    }
    if ($available.Voice) {
        & $addEndpoint 'Reporting.Endpoint.VoiceLocal' `
            $uris.VoiceLocal
    }
    if ($available.ComfyUI) {
        & $addEndpoint 'Reporting.Endpoint.ComfyUILocal' `
            $uris.ComfyUILocal
        & $addEndpoint 'Reporting.Endpoint.ComfyUILan' `
            $uris.ComfyUILan
    }
    return @($endpoints)
}
function Assert-ReportingEndpointProjectionContracts {
    [CmdletBinding()]
    param()
    $config = [pscustomobject][ordered]@{
        Ollama = [pscustomobject]@{
            Enabled = $false
            Host = '0.0.0.0'
            Port = 11434
        }
        OpenWebUI = [pscustomobject]@{
            Enabled = $false
            Host = '0.0.0.0'
            Port = 3000
        }
        Voice = [pscustomobject]@{
            Enabled = $false
            Host = '127.0.0.1'
            Port = 8880
        }
        ComfyUI = [pscustomobject]@{
            Enabled = $false
            Host = '0.0.0.0'
            Port = 8188
        }
        Security = [pscustomobject]@{
            LanAccess = $true
        }
    }
    $context = [pscustomobject]@{
        Config = $config
        RuntimeDegradedComponents = @()
    }
    $snapshot = $context | ConvertTo-Json -Compress -Depth 10
    $calls = [Collections.Generic.List[string]]::new()
    $disabled = @(Get-ReportingEndpointProjection `
        -Context $context -ProbeInvoker {
            param([string]$Name, [pscustomobject]$RuntimeContext)
            $calls.Add($Name)
            return $true
        })
    if ($disabled.Count -ne 0 -or $calls.Count -ne 0 -or
        ($context | ConvertTo-Json -Compress -Depth 10) -cne $snapshot) {
        throw 'Tum servisler kapali rapor endpoint sozlesmesi gecersiz.'
    }
    $context.Config.Voice.Enabled = $true
    $voiceSnapshot = $context | ConvertTo-Json -Compress -Depth 10
    $voice = @(Get-ReportingEndpointProjection `
        -Context $context -ProbeInvoker {
            param([string]$Name, [pscustomobject]$RuntimeContext)
            $calls.Add($Name)
            return $Name -ceq 'Voice'
        })
    if ($voice.Count -ne 1 -or
        $voice[0].LabelKey -cne 'Reporting.Endpoint.VoiceLocal' -or
        $voice[0].Uri -cne 'http://127.0.0.1:8880' -or
        $calls.Count -ne 1 -or $calls[0] -cne 'Voice' -or
        ($context | ConvertTo-Json -Compress -Depth 10) -cne
            $voiceSnapshot) {
        throw 'Yalniz ses etkin rapor endpoint sozlesmesi gecersiz.'
    }
    $unhealthy = @(Get-ReportingEndpointProjection `
        -Context $context -ProbeInvoker { return $false })
    $context.RuntimeDegradedComponents = @('Voice')
    $degradedCalls = [Collections.Generic.List[string]]::new()
    $degraded = @(Get-ReportingEndpointProjection `
        -Context $context -ProbeInvoker {
            param([string]$Name, [pscustomobject]$RuntimeContext)
            $degradedCalls.Add($Name)
            return $true
        })
    if ($unhealthy.Count -ne 0 -or $degraded.Count -ne 0 -or
        $degradedCalls.Count -ne 0) {
        throw 'Sagliksiz veya bozulmus servis rapora sizdi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Reporting.AllDisabledEndpoints'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Reporting.VoiceOnlyEndpoint'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Reporting.HealthProjection'
    return $true
}
function Write-DashboardReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $templatePath = Join-Path $Context.PackageRoot `
        'Modules\Dashboard\template.html'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        $templatePath = Join-Path $Context.AppPath `
            'Modules\Dashboard\template.html'
    }
    $template = Get-Content -LiteralPath $templatePath -Raw `
        -Encoding UTF8
    $state = Read-EngineState -Context $Context
    $hardware = $null
    $validation = $null
    $health = $null
    if (Test-Path -LiteralPath $Context.HardwarePath) {
        $hardware = Read-JsonFile -Path $Context.HardwarePath
    }
    if (Test-Path -LiteralPath $Context.ValidationPath) {
        $validation = Read-JsonFile -Path $Context.ValidationPath
    }
    if (Test-Path -LiteralPath $Context.HealthPath) {
        $health = Read-JsonFile -Path $Context.HealthPath
    }
    $stageRows = foreach ($entry in @($state.StageHistory)) {
        $class = if ($entry.Status -eq 'SUCCESS') { 'ok' } `
            elseif ($entry.Status -eq 'FAILED') { 'bad' } else { '' }
        '<tr><td>{0}</td><td class="{1}">{2}</td><td>{3}</td></tr>' -f `
            (ConvertTo-HtmlSafeText (Get-LocalizedText `
                -Key "Stage.$($entry.Stage)")), $class,
            (ConvertTo-HtmlSafeText (Get-LocalizedText `
                -Key "State.Status.$($entry.Status)")),
            (ConvertTo-HtmlSafeText $entry.At)
    }
    $stages = Get-LocalizedText -Key 'Reporting.StageTable' `
        -Arguments @(($stageRows -join ''))
    $hardwareHtml = Get-LocalizedText -Key 'Reporting.Empty'
    if ($null -ne $hardware) {
        $gpu = if (@($hardware.Gpus).Count -gt 0) {
            @($hardware.Gpus.Name) -join ', '
        }
        else {
            Get-LocalizedText -Key 'Reporting.CpuFallback'
        }
        $hardwareHtml = Get-LocalizedText `
            -Key 'Reporting.HardwareTable' `
            -Arguments @(
                (ConvertTo-HtmlSafeText $hardware.Cpu.Name),
                $hardware.RamGB,
                (ConvertTo-HtmlSafeText $gpu),
                $hardware.FreeDiskGB
            )
    }
    $healthHtml = Get-LocalizedText -Key 'Reporting.HealthWaiting'
    if ($null -ne $health) {
        $healthHtml = ConvertTo-CheckTable -Checks $health.Checks
    }
    $validationPath = Join-Path $Context.DataPath `
        'platform-validation.json'
    $platformValidation = $null
    if (Test-Path -LiteralPath $validationPath) {
        $platformValidation = Read-JsonFile -Path $validationPath
    }
    $platformChecks = $null
    if ($state.StageStatus -eq 'SUCCESS' -and
        $null -ne $platformValidation -and
        [bool]$platformValidation.Success) {
        $platformChecks = $platformValidation.Checks
    }
    $validationHtml = ConvertTo-CheckTable -Checks $platformChecks
    $logText = ''
    if (Test-Path -LiteralPath $Context.LogPath) {
        $logText = Get-Content -LiteralPath $Context.LogPath `
            -Tail 40 -Encoding UTF8 | ForEach-Object {
                try {
                    $entry = ConvertFrom-WinlamaJson -Json $_
                    '{0} [{1}] {2}: {3}' -f $entry.timestamp,
                        $entry.level, $entry.module, $entry.message
                }
                catch {
                    Write-Verbose ('Rapor log satiri JSON olarak okunamadi: {0}' `
                        -f $_.Exception.Message)
                    $_
                }
            } | Out-String
    }
    $latency = Get-LocalizedText -Key 'Reporting.Waiting'
    if ($null -ne $validation) {
        $latency = "$($validation.LatencyMilliseconds) ms"
    }
    $endpoints = @(Get-ReportingEndpointProjection -Context $Context)
    $endpointRows = @(foreach ($endpoint in $endpoints) {
        $label = ConvertTo-HtmlSafeText `
            (Get-LocalizedText -Key $endpoint.LabelKey)
        $uri = ConvertTo-HtmlSafeText $endpoint.Uri
        ('<tr><td>{0}</td><td><a href="{1}" target="_blank" ' +
            'rel="noopener">{1}</a></td></tr>') -f $label, $uri
    })
    $endpointsHtml = if ($endpointRows.Count -eq 0) {
        Get-LocalizedText -Key 'Reporting.Empty'
    }
    else {
        '<table><tbody>{0}</tbody></table>' -f ($endpointRows -join '')
    }
    $replacements = [ordered]@{
        '{{ENGINE_VERSION}}' = ConvertTo-HtmlSafeText `
            $Context.Config.EngineVersion
        '{{PAGE_TITLE}}' = Get-LocalizedText -Key 'Reporting.PageTitle'
        '{{SUMMARY_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.SummaryTitle'
        '{{MACHINE_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.MachineTitle'
        '{{MODEL_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.ModelTitle'
        '{{INFERENCE_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.InferenceTitle'
        '{{ENDPOINTS_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.EndpointsTitle'
        '{{STAGES_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.StagesTitle'
        '{{HARDWARE_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.HardwareTitle'
        '{{HEALTH_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.HealthTitle'
        '{{VALIDATION_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.ValidationTitle'
        '{{LOGS_TITLE}}' = Get-LocalizedText `
            -Key 'Reporting.LogsTitle'
        '{{GENERATED_AT}}' = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
        '{{STATUS_CLASS}}' = ConvertTo-HtmlSafeText `
            $state.StageStatus
        '{{STATUS}}' = ConvertTo-HtmlSafeText (Get-LocalizedText `
            -Key "State.Status.$($state.StageStatus)")
        '{{MACHINE}}' = ConvertTo-HtmlSafeText $env:COMPUTERNAME
        '{{MODELS}}' = ConvertTo-HtmlSafeText `
            (@($state.SelectedModels) -join ', ')
        '{{LATENCY}}' = ConvertTo-HtmlSafeText $latency
        '{{ENDPOINTS}}' = $endpointsHtml
        '{{STAGES}}' = $stages
        '{{HARDWARE}}' = $hardwareHtml
        '{{HEALTH}}' = $healthHtml
        '{{VALIDATION}}' = $validationHtml
        '{{LOGS}}' = ConvertTo-HtmlSafeText $logText
    }
    $html = $template
    foreach ($entry in $replacements.GetEnumerator()) {
        $html = $html.Replace($entry.Key, $entry.Value)
    }
    $mutex = [Threading.Mutex]::new(
        $false,
        'Global\WinlamaDashboard'
    )
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            Write-Verbose ('Birakilmis rapor kilidi devralindi: {0}' -f `
                $_.Exception.Message)
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw (Get-LocalizedText `
                -Key 'Reporting.Error.LockUnavailable')
        }
        $Context.DashboardPath = Get-WinlamaTimestampedPath `
            -Directory $Context.ReportsPath -Extension '.html' `
            -Prefix 'report-'
        Write-AtomicTextFile -Path $Context.DashboardPath -Content $html
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}
Export-ModuleMember -Function @(
    'ConvertTo-HtmlSafeText', 'Get-ReportingEndpointProjection',
    'Assert-ReportingEndpointProjectionContracts',
    'Write-DashboardReport'
)