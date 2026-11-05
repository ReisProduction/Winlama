Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-PortListener {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    return Get-NetTCPConnection -State Listen -LocalPort $Port `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}
function Invoke-AiRuntimeHealthProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][bool]$Degraded,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    if (-not $Enabled -or $Degraded) {
        return $true
    }
    return [bool](& $Probe)
}
function Set-AiRuntimeDegradedComponents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Components
    )
    $Context | Add-Member -NotePropertyName `
        'RuntimeDegradedComponents' -NotePropertyValue @($Components) -Force
}
function Add-AiRuntimeDegradedComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Name
    )
    $current = @()
    $property = $Context.PSObject.Properties[
        'RuntimeDegradedComponents'
    ]
    if ($null -ne $property) {
        $current = @($property.Value)
    }
    Set-AiRuntimeDegradedComponents -Context $Context `
        -Components @($current + $Name | Sort-Object -Unique)
}
function Test-AiRuntimeComponentDegraded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Name
    )
    $property = $Context.PSObject.Properties[
        'RuntimeDegradedComponents'
    ]
    return $null -ne $property -and $Name -iin @($property.Value)
}
function Test-AiRuntimeContinueOnOptionalError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $installation = $Context.Config.PSObject.Properties['Installation']
    if ($null -eq $installation) {
        return $false
    }
    $property = $installation.Value.PSObject.Properties[
        'ContinueOnOptionalError'
    ]
    return $null -ne $property -and [bool]$property.Value
}
function Disable-AiRuntimeOptionalComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('Voice', 'ComfyUI')]
        [string]$Name,
        [scriptblock]$ConfigWriter
    )
    $section = $Context.Config.PSObject.Properties[$Name]
    if ($null -eq $section -or
        $null -eq $section.Value.PSObject.Properties['Enabled']) {
        throw [IO.InvalidDataException]::new(
            "Opsiyonel runtime config bolumu gecersiz: $Name"
        )
    }
    $section.Value.Enabled = $false
    Add-AiRuntimeDegradedComponent -Context $Context -Name $Name
    if ($null -ne $ConfigWriter) {
        $null = & $ConfigWriter $Context.Config
        return
    }
    $configPath = Get-WinlamaConfigPath -Context $Context
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new(
            "Etkin runtime config dosyasi bulunamadi: $configPath"
        )
    }
    Write-AtomicTextFile -Path $configPath -Content (
        ConvertTo-StableJson -Value $Context.Config -Depth 100
    )
}
function Test-OllamaLoopbackListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $listeners = @(Get-NetTCPConnection -State Listen `
        -LocalPort $Context.Config.Ollama.Port `
        -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) {
        return $false
    }
    $networkListeners = @($listeners | Where-Object {
        $_.LocalAddress -notin @(
            '127.0.0.1', '::1', '::ffff:127.0.0.1'
        )
    })
    return $networkListeners.Count -eq 0
}
function Stop-ProcessesFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [int]$TimeoutSeconds = 30,
        [scriptblock]$ProcessReader = {
            Get-CimInstance -ClassName Win32_Process `
                -ErrorAction Stop
        },
        [scriptblock]$ProcessStopper = {
            param([int]$ProcessId)
            Stop-Process -Id $ProcessId -Force `
                -ErrorAction SilentlyContinue
        },
        [scriptblock]$Delay = {
            Start-Sleep -Milliseconds 500
        }
    )
    $prefix = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    $readMatchingProcesses = {
        try {
            $candidates = @(& $ProcessReader)
        }
        catch {
            throw [InvalidOperationException]::new(
                (Get-LocalizedText `
                    -Key 'Runtime.Error.ProcessEnumerationFailed' `
                    -Arguments @($RootPath, $_.Exception.Message)),
                $_.Exception
            )
        }
        return @($candidates | Where-Object {
            $path = [string]$_.ExecutablePath
            -not [string]::IsNullOrWhiteSpace($path) -and
                [IO.Path]::GetFullPath($path).StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
        })
    }.GetNewClosure()
    $processes = @(& $readMatchingProcesses)
    foreach ($process in $processes) {
        & $ProcessStopper -ProcessId $process.ProcessId
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remaining = @(& $readMatchingProcesses)
        if ($remaining.Count -eq 0) {
            return
        }
        & $Delay
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw (Get-LocalizedText -Key 'Runtime.Error.ProcessStopTimeout' `
        -Arguments @($RootPath, $TimeoutSeconds))
}
function Assert-StopProcessesFromPathContracts {
    $root = 'C:\Fixture\ComfyUI'
    $state = [pscustomobject]@{
        Reads = 0
        Stopped = [Collections.Generic.List[int]]::new()
    }
    $reader = {
        $state.Reads++
        if ($state.Reads -eq 1) {
            return [pscustomobject]@{
                ProcessId = 4242
                ExecutablePath = Join-Path $root 'python.exe'
            }
        }
        return @()
    }.GetNewClosure()
    $stopper = {
        param([int]$ProcessId)
        $state.Stopped.Add($ProcessId)
    }.GetNewClosure()
    Stop-ProcessesFromPath -RootPath $root -TimeoutSeconds 1 `
        -ProcessReader $reader -ProcessStopper $stopper -Delay {}
    $enumerationFailed = $false
    try {
        Stop-ProcessesFromPath -RootPath $root -TimeoutSeconds 1 `
            -ProcessReader { throw 'CIM_FIXTURE_FAILURE' } `
            -ProcessStopper { param([int]$ProcessId) } -Delay {}
    }
    catch {
        $enumerationFailed = $_.Exception.Message -match
            'CIM_FIXTURE_FAILURE'
    }
    $source = (Get-Command Stop-ProcessesFromPath `
        -ErrorAction Stop).Definition
    if ($state.Reads -ne 2 -or $state.Stopped.Count -ne 1 -or
        $state.Stopped[0] -ne 4242 -or -not $enumerationFailed -or
        $source -notmatch 'Get-CimInstance[\s\S]+-ErrorAction Stop') {
        throw 'Runtime surec durdurma sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.ProcessStopFailClosed'
    return $true
}
function Set-ProcessesFromPathPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)]
        [ValidateSet('Normal', 'AboveNormal', 'High')]
        [string]$Priority
    )
    $result = [ordered]@{
        Total = 0
        Updated = 0
        Failed = 0
    }
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return [pscustomobject]$result
    }
    $prefix = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    $processes = @(Get-CimInstance -ClassName Win32_Process `
        -ErrorAction SilentlyContinue | Where-Object {
            $path = [string]$_.ExecutablePath
            -not [string]::IsNullOrWhiteSpace($path) -and
                [IO.Path]::GetFullPath($path).StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
        })
    foreach ($process in $processes) {
        $result.Total++
        if (Set-WinlamaProcessPriority -Priority $Priority `
            -ProcessId $process.ProcessId) {
            $result.Updated++
        }
        else {
            $result.Failed++
        }
    }
    return [pscustomobject]$result
}
function Set-AiRuntimePriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $priority = [string]$Context.Config.Runtime.ProcessPriority
    $ollama = if ($Context.Config.Ollama.Enabled) {
        Set-ProcessesFromPathPriority `
            -RootPath (Get-OllamaInstallPath -Context $Context) `
            -Priority $priority
    }
    else {
        [pscustomobject]@{ Total = 0; Updated = 0; Failed = 0 }
    }
    $webUI = if ($Context.Config.OpenWebUI.Enabled) {
        Set-ProcessesFromPathPriority `
            -RootPath (Get-OpenWebUIRuntimePath -Context $Context) `
            -Priority $priority
    }
    else {
        [pscustomobject]@{ Total = 0; Updated = 0; Failed = 0 }
    }
    $ollamaLevel = if (-not $Context.Config.Ollama.Enabled -or
        ($ollama.Total -gt 0 -and $ollama.Failed -eq 0)) {
        'OK'
    }
    else {
        'WARN'
    }
    $webUILevel = if (-not $Context.Config.OpenWebUI.Enabled -or
        ($webUI.Total -gt 0 -and $webUI.Failed -eq 0)) {
        'OK'
    }
    else {
        'WARN'
    }
    if ($Context.Config.Ollama.Enabled) {
        Write-DeploymentLog -Context $Context -Level $ollamaLevel `
            -Module RUNTIME -Message 'Runtime.Priority.OllamaApplied' `
            -MessageArguments @(
                $priority, $ollama.Updated, $ollama.Failed
            )
    }
    if ($Context.Config.OpenWebUI.Enabled) {
        Write-DeploymentLog -Context $Context -Level $webUILevel `
            -Module RUNTIME -Message 'Runtime.Priority.WebUIApplied' `
            -MessageArguments @(
                $priority, $webUI.Updated, $webUI.Failed
            )
    }
}
function Start-OllamaApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$Restart,
        [switch]$Attached
    )
    $runtimePath = Join-Path $Context.DataPath 'ollama.runtime.json'
    $runtime = if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
        Read-JsonFile -Path $runtimePath
    }
    else {
        $null
    }
    $application = Get-OllamaApplicationExecutable -Context $Context
    $arguments = @(Get-OllamaApplicationArgumentList)
    $apiReady = Test-OllamaApiReady -Context $Context
    $safeListener = $apiReady -and
        (Test-OllamaLoopbackListener -Context $Context)
    $applicationReady = Test-OllamaApplicationRunning -Context $Context
    $environmentChanged = $null -ne $runtime -and
        $null -ne $runtime.PSObject.Properties['EnvironmentChanged'] -and
        [bool]$runtime.EnvironmentChanged
    if (-not $Restart -and $apiReady -and $safeListener -and $applicationReady -and
        -not $environmentChanged) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module RUNTIME -Message 'Runtime.Ollama.AlreadyReady'
        return
    }
    if ($apiReady -and -not $safeListener) {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module RUNTIME `
            -Message 'Runtime.Ollama.UnsafeListenerRestart'
    }
    $installPath = Get-OllamaInstallPath -Context $Context
    Stop-ProcessesFromPath -RootPath $installPath `
        -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
    $listener = Get-PortListener -Port $Context.Config.Ollama.Port
    if ($null -ne $listener) {
        throw (Get-LocalizedText -Key 'Runtime.Error.OllamaPortOccupied' `
            -Arguments @(
                $Context.Config.Ollama.Port,
                $listener.OwningProcess
            ))
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module RUNTIME -Message 'Runtime.Ollama.Starting'
    $start = @{
        FilePath = $application
        ArgumentList = $arguments
        WorkingDirectory = Split-Path -Parent $application
        PassThru = $true
    }
    $process = Start-Process @start
    try {
        $null = Set-WinlamaProcessPriority `
            -Priority $Context.Config.Runtime.ProcessPriority `
            -ProcessId $process.Id
        $null = Wait-OllamaReady -Context $Context `
            -TimeoutSeconds `
                $Context.Config.Runtime.OllamaStartupTimeoutSeconds
        $loopbackReady = Test-OllamaLoopbackListener -Context $Context
        $trayReady = Test-OllamaApplicationRunning -Context $Context
        if (-not $trayReady) {
            throw 'Ollama tray uygulamasi baslatilamadi.'
        }
        if (-not $loopbackReady) {
            throw (Get-LocalizedText `
                -Key 'Runtime.Error.OllamaUnsafeListener')
        }
    }
    catch {
        $failure = $_
        try {
            Stop-ProcessesFromPath -RootPath $installPath `
                -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
        }
        catch {
            Write-Verbose ('Ollama hata temizligi basarisiz: {0}' -f `
                $_.Exception.Message)
        }
        throw $failure
    }
    finally {
        $process.Dispose()
    }
    if ($null -ne $runtime) {
        $runtime | Add-Member -NotePropertyName Application `
            -NotePropertyValue $application -Force
        $runtime.EnvironmentChanged = $false
        Write-AtomicTextFile -Path $runtimePath `
            -Content (ConvertTo-StableJson -Value $runtime -Depth 10)
    }
    Write-DeploymentLog -Context $Context -Level OK `
        -Module RUNTIME -Message 'Runtime.Ollama.Ready'
}
function Assert-OllamaRuntimeLaunchContracts {
    [CmdletBinding()]
    param()
    $null = Assert-ExternalProcessContracts
    $null = Assert-OllamaApplicationContracts
    $source = (Get-Command Start-OllamaApplication `
        -ErrorAction Stop).Definition
    if ($source -notmatch 'Get-OllamaApplicationExecutable' -or
        $source -notmatch 'Get-OllamaApplicationArgumentList' -or
        $source -notmatch 'Test-OllamaApplicationRunning' -or
        $source -notmatch '\$Restart' -or
        $source -match 'Get-Process\s+-Name' -or
        $source -match 'Get-OllamaExecutable' -or
        $source -match "ArgumentList\s*=\s*'serve'" -or
        $source -match 'NoNewWindow' -or
        $source -notmatch '\$failure = \$_' -or
        $source -notmatch
            'finally\s*\{\s*\$process\.Dispose\(\)') {
        throw 'Ollama runtime tray baslatma sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.OllamaTrayLaunch'
    return $true
}
function Test-OpenWebUIReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.OpenWebUI.Enabled) {
        return $true
    }
    return Test-HttpEndpoint `
        -Uri (Get-OpenWebUIHealthUri -Context $Context) `
        -TimeoutMilliseconds 5000
}
function Save-RuntimeConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $configsDir = Join-Path $Context.DataPath 'Configs'
    [IO.Directory]::CreateDirectory($configsDir) | Out-Null
    $configDest = Join-Path $configsDir 'config.json'
    Write-AtomicTextFile -Path $configDest `
        -Content (ConvertTo-StableJson `
            -Value $Context.Config -Depth 100)
}
function Resolve-OpenWebUIPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (Test-OpenWebUIReady -Context $Context) {
        return [int]$Context.Config.OpenWebUI.Port
    }
    if ($null -eq (Get-PortListener `
        -Port $Context.Config.OpenWebUI.Port)) {
        return [int]$Context.Config.OpenWebUI.Port
    }
    foreach ($port in @($Context.Config.OpenWebUI.FallbackPorts)) {
        if ($null -eq (Get-PortListener -Port $port)) {
            $previous = [int]$Context.Config.OpenWebUI.Port
            $Context.Config.OpenWebUI.Port = [int]$port
            $origins = Get-LocalHttpOrigins -Port $port `
                -IncludeNetwork:$Context.Config.Security.LanAccess
            $Context.Config.Ollama.AllowedOrigins = $origins
            [Environment]::SetEnvironmentVariable(
                'OLLAMA_ORIGINS',
                ($origins -join ','),
                [EnvironmentVariableTarget]::User
            )
            $env:OLLAMA_ORIGINS = $origins -join ','
            Save-RuntimeConfiguration -Context $Context
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module RUNTIME -Message 'Runtime.WebUI.PortChanged' `
                -MessageArguments @($previous, $port)
            return [int]$port
        }
    }
    throw (Get-LocalizedText -Key 'Runtime.Error.WebUIPortUnavailable')
}
function Set-OpenWebUIEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $root = Get-OpenWebUIRootPath -Context $Context
    $data = Get-OpenWebUIDataPath -Context $Context
    $port = [int]$Context.Config.OpenWebUI.Port
    $origins = Get-LocalHttpOrigins -Port $port `
        -IncludeNetwork:$Context.Config.Security.LanAccess
    $webUIHost = if ($Context.Config.Security.LanAccess) {
        Get-WinlamaLanHost
    }
    else {
        $Context.Config.OpenWebUI.HealthHost
    }
    $temporaryMediaPath = [IO.Path]::GetFullPath(
        (Join-Path ([IO.Path]::GetTempPath()) 'Winlama\OpenWebUI')
    )
    foreach ($path in @(
        $temporaryMediaPath,
        (Join-Path $data 'cache\audio\speech'),
        (Join-Path $data 'cache\image\generations')
    )) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Force |
                Remove-Item -Recurse -Force -ErrorAction Stop
        }
    }
    $values = [ordered]@{
        DATA_DIR = $data
        OLLAMA_BASE_URL = Get-OllamaBaseUri -Context $Context
        WEBUI_SECRET_KEY = New-WebUISecret -Context $Context
        WEBUI_AUTH = $Context.Config.OpenWebUI.AuthEnabled.ToString().
            ToLowerInvariant()
        UVICORN_WORKERS = [string]$Context.Config.OpenWebUI.Workers
        CORS_ALLOW_ORIGIN = $origins -join ';'
        WEBUI_URL = "http://$webUIHost`:$port"
        USER_AGENT = "Winlama/$($Context.Config.EngineVersion)"
        HF_HOME = Join-Path $data 'cache\huggingface'
        XDG_CACHE_HOME = Join-Path $data 'cache'
        TEMP = $temporaryMediaPath
        TMP = $temporaryMediaPath
    }
    foreach ($property in `
        $Context.Config.OpenWebUI.Environment.PSObject.Properties) {
        $values[$property.Name] = [string]$property.Value
    }
    foreach ($path in @(
        $root,
        $data,
        (Join-Path $root 'logs'),
        $values.HF_HOME,
        $values.XDG_CACHE_HOME,
        $values.TEMP
    )) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    foreach ($entry in $values.GetEnumerator()) {
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
    Set-WinlamaArrowSimdCompatibility
}
function Stop-OpenWebUIRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.OpenWebUI.Enabled) {
        return
    }
    $executable = Get-OpenWebUIExecutablePath -Context $Context
    $readWebUIProcesses = {
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object {
                [string]$_.ExecutablePath -ieq $executable -or
                    ([string]$_.CommandLine).IndexOf(
                        $executable, [StringComparison]::OrdinalIgnoreCase
                    ) -ge 0
            }
    }.GetNewClosure()
    Stop-ProcessesFromPath `
        -RootPath (Get-OpenWebUIRuntimePath -Context $Context) `
        -ProcessReader $readWebUIProcesses `
        -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
}
function Start-OpenWebUIRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$Mode = 'Keep',
        [switch]$Attached
    )
    if (-not $Context.Config.OpenWebUI.Enabled -or $Mode -eq 'Skip') {
        return
    }
    $null = Resolve-OpenWebUIPort -Context $Context
    $ready = Test-OpenWebUIReady -Context $Context
    if ($ready -and $Mode -eq 'Keep') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module RUNTIME -Message 'Runtime.WebUI.AlreadyReady'
        return
    }
    Stop-OpenWebUIRuntime -Context $Context
    $executable = Get-OpenWebUIExecutablePath -Context $Context
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'Runtime.Error.WebUIExecutableMissing')
    }
    Set-OpenWebUIEnvironment -Context $Context
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module RUNTIME -Message 'Runtime.WebUI.Starting'
    $start = @{
        FilePath = $executable
        ArgumentList = @(
            'serve', '--host', [string]$Context.Config.OpenWebUI.Host,
            '--port', [string]$Context.Config.OpenWebUI.Port
        )
        WorkingDirectory = Get-OpenWebUIRootPath -Context $Context
        PassThru = $true
    }
    $errorPath = 'aktif terminal'
    if ($Attached) {
        $start.NoNewWindow = $true
    }
    else {
        $logDirectory = Join-Path `
            (Get-OpenWebUIRootPath -Context $Context) 'logs'
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputPath = Join-Path $logDirectory "$stamp-cikti.log"
        $errorPath = Join-Path $logDirectory "$stamp-hata.log"
        $start.WindowStyle = 'Hidden'
        $start.RedirectStandardOutput = $outputPath
        $start.RedirectStandardError = $errorPath
    }
    $process = Start-Process @start
    $null = Set-WinlamaProcessPriority `
        -Priority $Context.Config.Runtime.ProcessPriority `
        -ProcessId $process.Id
    $timeout = [int]$Context.Config.OpenWebUI.StartupTimeoutSeconds
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($timeout)
    $nextLog = [DateTimeOffset]::UtcNow
    do {
        if (Test-OpenWebUIReady -Context $Context) {
            Write-DeploymentLog -Context $Context -Level OK `
                -Module RUNTIME -Message 'Runtime.WebUI.Ready'
            $process.Dispose()
            return
        }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            $process.Dispose()
            throw (Get-LocalizedText -Key 'Runtime.Error.WebUIExited' `
                -Arguments @($exitCode, $errorPath))
        }
        if ([DateTimeOffset]::UtcNow -ge $nextLog) {
            $remaining = [math]::Max(
                0,
                [math]::Ceiling(
                    ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds
                )
            )
            Write-DeploymentLog -Context $Context -Level WAITING `
                -Module RUNTIME -Message 'Runtime.WebUI.Waiting' `
                -MessageArguments @($remaining)
            $nextLog = [DateTimeOffset]::UtcNow.AddSeconds(
                $Context.Config.Runtime.ProgressLogIntervalSeconds
            )
        }
        Start-Sleep -Seconds $Context.Config.Runtime.PollIntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Stop-OpenWebUIRuntime -Context $Context
    $process.Dispose()
    throw (Get-LocalizedText -Key 'Runtime.Error.WebUIHealthTimeout' `
        -Arguments @($timeout, $errorPath))
}
function Get-WinlamaTtsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return 'http://{0}:{1}' -f `
        $Context.Config.Voice.Host,
        $Context.Config.Voice.Port
}
function Test-WinlamaTtsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Voice.Enabled) {
        return $true
    }
    try {
        $handler = [Net.Http.HttpClientHandler]::new()
        $client = [Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(5)
            $uri = "$(Get-WinlamaTtsUri -Context $Context)/health"
            $response = $client.GetAsync($uri).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    return $false
                }
                $contentTask = $response.Content.ReadAsStringAsync()
                $json = $contentTask.GetAwaiter().GetResult()
                $health = $json | ConvertFrom-Json -ErrorAction Stop
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $client.Dispose()
            $handler.Dispose()
        }
        $bilingual = $Context.Config.Voice.PSObject.Properties['Bilingual']
        return Test-WinlamaTtsHealthContract -Health $health `
            -ExpectedBilingual:($null -ne $bilingual -and [bool]$bilingual.Value) `
            -ExpectedModel ([string]$Context.Config.Voice.Model) `
            -ExpectedRevision ([string]$Context.Config.Voice.Revision) `
            -ExpectedLanguage ([string]$Context.Config.Voice.Language)
    }
    catch {
        Write-Verbose ('TTS saglik denetimi basarisiz: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Test-WinlamaTtsHealthContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Health,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [Parameter(Mandatory)]
        [ValidateSet('tr', 'en')]
        [string]$ExpectedLanguage,
        [switch]$ExpectedBilingual
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedModel) -or
        $ExpectedRevision -notmatch '^[a-f0-9]{40}$') {
        return $false
    }
    try {
        $ready = $Health.PSObject.Properties['ready']
        $model = $Health.PSObject.Properties['model']
        $revision = $Health.PSObject.Properties['revision']
        $language = $Health.PSObject.Properties['language']
        $voices = $Health.PSObject.Properties['voices']
        $expectedVoices = if ($ExpectedBilingual) { 'en,tr' } else { $ExpectedLanguage }
        if (($ExpectedBilingual -and $null -eq $voices) -or
            ($null -ne $voices -and (($voices.Value | Sort-Object) -join ',') -cne $expectedVoices)) {
            return $false
        }
        return $null -ne $ready -and $ready.Value -is [bool] -and
            [bool]$ready.Value -and $null -ne $model -and
            [string]$model.Value -ceq $ExpectedModel -and
            $null -ne $revision -and
            [string]$revision.Value -ceq $ExpectedRevision -and
            $null -ne $language -and
            [string]$language.Value -ceq $ExpectedLanguage
    }
    catch {
        return $false
    }
}
function Get-WinlamaTtsMessageKeys {
    [CmdletBinding()]
    param()
    return @(
        'Tts.Api.InternalError',
        'Tts.Api.MethodNotAllowed',
        'Tts.Api.NotFound',
        'Tts.Api.RequestInvalid',
        'Tts.Cli.Description',
        'Tts.Cli.Help',
        'Tts.Cli.HostHelp',
        'Tts.Cli.InvalidArguments',
        'Tts.Cli.PortHelp',
        'Tts.Error.LanguageUnsupported',
        'Tts.Error.LoopbackOnly',
        'Tts.Error.ModelNotReady',
        'Tts.Error.ModelUnsupported',
        'Tts.Error.SynthesisFailed',
        'Tts.Error.VoiceUnsupported',
        'Tts.Log.SynthesisFailed',
        'Tts.Log.UnexpectedFailure',
        'Tts.Voice.en',
        'Tts.Voice.tr'
    )
}
function Get-WinlamaTtsLocalizedMessages {
    [CmdletBinding()]
    param()
    $messages = [ordered]@{}
    foreach ($key in @(Get-WinlamaTtsMessageKeys)) {
        $value = [string](Get-LocalizedText -Key $key)
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value -ceq $key) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.LocalizationKeyUnresolved' `
                -Arguments @($key))
        }
        $messages[$key] = $value
    }
    return $messages
}
function Assert-WinlamaTtsRuntimeContracts {
    [CmdletBinding()]
    param()
    $expectedModel = 'facebook/mms-tts-tur'
    $expectedRevision = '7e364479c307f06733ca865b0a5269e0209cf82d'
    $good = [pscustomobject][ordered]@{
        model = $expectedModel
        revision = $expectedRevision
        language = 'tr'
        ready = $true
    }
    $goodBefore = $good | ConvertTo-Json -Compress
    if (-not (Test-WinlamaTtsHealthContract -Health $good `
        -ExpectedModel $expectedModel `
        -ExpectedRevision $expectedRevision `
        -ExpectedLanguage tr)) {
        throw 'TTS iyi health fixture kabul edilmedi.'
    }
    $englishGood = [pscustomobject][ordered]@{
        model = 'facebook/mms-tts-eng'
        revision = 'c71de0fe7204c83f1c10820a7d696d0b450048ba'
        language = 'en'
        ready = $true
    }
    if (-not (Test-WinlamaTtsHealthContract -Health $englishGood `
        -ExpectedModel $englishGood.model `
        -ExpectedRevision $englishGood.revision `
        -ExpectedLanguage en)) {
        throw 'Ingilizce TTS health fixture kabul edilmedi.'
    }
    foreach ($bad in @(
        [pscustomobject]@{
            model = $expectedModel
            revision = $expectedRevision
            language = 'tr'
            ready = $false
        },
        [pscustomobject]@{
            model = $null
            revision = $expectedRevision
            language = 'tr'
            ready = $true
        },
        [pscustomobject]@{
            model = 'other/model'
            revision = $expectedRevision
            language = 'tr'
            ready = $true
        },
        [pscustomobject]@{
            model = $expectedModel
            revision = '0000000000000000000000000000000000000000'
            language = 'tr'
            ready = $true
        },
        [pscustomobject]@{
            model = $expectedModel
            revision = $expectedRevision
            language = 'en'
            ready = $true
        },
        [pscustomobject]@{
            model = $expectedModel
            revision = $expectedRevision
            language = 'tr'
            ready = 'true'
        },
        [pscustomobject]@{
            model = $expectedModel
            revision = $expectedRevision
            language = 'tr'
        }
    )) {
        if (Test-WinlamaTtsHealthContract -Health $bad `
            -ExpectedModel $expectedModel `
            -ExpectedRevision $expectedRevision `
            -ExpectedLanguage tr) {
            throw 'TTS bozuk health fixture reddedilmedi.'
        }
    }
    if (($good | ConvertTo-Json -Compress) -cne $goodBefore) {
        throw 'TTS runtime fixture denetimi girdiyi degistirdi.'
    }
    $messageKeys = @(Get-WinlamaTtsMessageKeys)
    $messageMap = Get-WinlamaTtsLocalizedMessages
    $messageJson = $messageMap | ConvertTo-Json -Compress
    $messageDocument = $messageJson | ConvertFrom-Json
    if ($messageKeys.Count -ne 19 -or
        @($messageKeys | Select-Object -Unique).Count -ne 19 -or
        $messageMap.Count -ne 19 -or
        @($messageDocument.PSObject.Properties).Count -ne 19) {
        throw 'TTS yerellestirme haritasi sozlesmesi gecersiz.'
    }
    foreach ($key in $messageKeys) {
        $property = $messageDocument.PSObject.Properties[$key]
        if ($null -eq $property -or
            [string]::IsNullOrWhiteSpace([string]$property.Value) -or
            [string]$property.Value -ceq $key) {
            throw "TTS yerellestirme degeri gecersiz: $key"
        }
    }
    $readySource = (Get-Command Test-WinlamaTtsReady `
        -ErrorAction Stop).Definition
    $startSource = (Get-Command Start-WinlamaTtsRuntime `
        -ErrorAction Stop).Definition
    if ($readySource -match 'Invoke-RestMethod' -or
        $readySource -notmatch 'Net\.Http\.HttpClient' -or
        $startSource -notmatch 'WINLAMA_TTS_LANGUAGE' -or
        $startSource -match 'cache\\huggingface\\mms-tts-tur') {
        throw 'TTS dil veya sessiz health probe sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:TTS.RuntimeContracts'
    Write-Verbose 'WINLAMA_VALIDATION_OK:TTS.EnglishSelection'
    Write-Verbose 'WINLAMA_VALIDATION_OK:TTS.SilentHealthProbe'
    Write-Verbose 'WINLAMA_VALIDATION_OK:TTS.LocalizationMap'
    return $true
}
function Stop-WinlamaTtsRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Voice.Enabled) {
        return
    }
    $runtimePath = Join-Path $Context.DataPath 'tts.runtime.json'
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        return
    }
    try {
        $runtime = Read-JsonFile -Path $runtimePath
        $process = Get-Process -Id ([int]$runtime.ProcessId) `
            -ErrorAction SilentlyContinue
        if ($null -ne $process -and
            [string]$process.Path -ieq [string]$runtime.PythonPath) {
            Stop-Process -Id $process.Id -Force `
                -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -LiteralPath $runtimePath -Force `
            -ErrorAction SilentlyContinue
    }
}
function Start-WinlamaTtsRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$Mode = 'Keep',
        [switch]$Attached
    )
    if (-not $Context.Config.Voice.Enabled -or $Mode -eq 'Skip') {
        return
    }
    $ready = Test-WinlamaTtsReady -Context $Context
    if ($ready -and $Mode -eq 'Keep') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module RUNTIME -Message 'Runtime.Tts.AlreadyReady'
        return
    }
    Stop-WinlamaTtsRuntime -Context $Context
    $listener = Get-PortListener -Port $Context.Config.Voice.Port
    if ($null -ne $listener) {
        throw (Get-LocalizedText -Key 'Runtime.Error.TtsPortOccupied' `
            -Arguments @(
                $Context.Config.Voice.Port,
                $listener.OwningProcess
            ))
    }
    $python = Get-OpenWebUIPythonPath -Context $Context
    $server = Join-Path $Context.AppPath 'Services\TtsServer.py'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or
        -not (Test-Path -LiteralPath $server -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Runtime.Error.TtsRuntimeMissing')
    }
    $root = Get-OpenWebUIRootPath -Context $Context
    $cacheName = ([string]$Context.Config.Voice.Model).Split('/')[-1]
    if ($cacheName -notmatch '^[a-z0-9._-]+$') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Voice.Model'))
    }
    $cacheDirectory = Join-Path $Context.DataPath `
        "cache\huggingface\$cacheName"
    foreach ($path in @($cacheDirectory)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    Set-WinlamaArrowSimdCompatibility
    $env:WINLAMA_TTS_MODEL = [string]$Context.Config.Voice.Model
    $env:WINLAMA_TTS_REVISION = [string]$Context.Config.Voice.Revision
    $env:WINLAMA_TTS_LANGUAGE = [string]$Context.Config.Voice.Language
    $bilingual = $Context.Config.Voice.PSObject.Properties['Bilingual']
    $env:WINLAMA_TTS_BILINGUAL = if ($null -ne $bilingual -and [bool]$bilingual.Value) { '1' } else { '0' }
    $env:WINLAMA_TTS_CACHE = $cacheDirectory
    $env:WINLAMA_TTS_MESSAGES = (
        Get-WinlamaTtsLocalizedMessages | ConvertTo-Json -Compress
    )
    $arguments = @(
        (ConvertTo-WindowsCommandLineArgument -Argument $server),
        '--host', [string]$Context.Config.Voice.Host,
        '--port', [string]$Context.Config.Voice.Port
    )
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module RUNTIME -Message 'Runtime.Tts.Starting'
    $start = @{
        FilePath = $python
        ArgumentList = $arguments
        WorkingDirectory = $root
        PassThru = $true
    }
    $errorPath = 'aktif terminal'
    if ($Attached) {
        $start.NoNewWindow = $true
    }
    else {
        $logDirectory = Join-Path $root 'logs'
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputPath = Join-Path $logDirectory "$stamp-tts-cikti.log"
        $errorPath = Join-Path $logDirectory "$stamp-tts-hata.log"
        $start.WindowStyle = 'Hidden'
        $start.RedirectStandardOutput = $outputPath
        $start.RedirectStandardError = $errorPath
    }
    $process = Start-Process @start
    Write-AtomicTextFile `
        -Path (Join-Path $Context.DataPath 'tts.runtime.json') `
        -Content (ConvertTo-StableJson -Depth 5 -Value `
            ([pscustomobject]@{
                ProcessId = $process.Id
                PythonPath = $python
                StartedAt = [DateTimeOffset]::UtcNow.ToString('O')
            }))
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(
        [int]$Context.Config.Voice.StartupTimeoutSeconds
    )
    do {
        if (Test-WinlamaTtsReady -Context $Context) {
            $null = Set-WinlamaProcessPriority `
                -Priority $Context.Config.Runtime.ProcessPriority `
                -ProcessId $process.Id
            $process.Dispose()
            Write-DeploymentLog -Context $Context -Level OK `
                -Module RUNTIME -Message 'Runtime.Tts.Ready'
            return
        }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            $process.Dispose()
            throw (Get-LocalizedText -Key 'Runtime.Error.TtsExited' `
                -Arguments @($exitCode, $errorPath))
        }
        Start-Sleep -Seconds $Context.Config.Runtime.PollIntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Stop-WinlamaTtsRuntime -Context $Context
    $process.Dispose()
    throw (Get-LocalizedText -Key 'Runtime.Error.TtsHealthTimeout' `
        -Arguments @(
            $Context.Config.Voice.StartupTimeoutSeconds,
            $errorPath
        ))
}
function Test-ComfyUIRuntimeLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path `
        'python_embeded\python.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
            'ComfyUI\main.py') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path `
            'run_nvidia_gpu_fast_fp16_accumulation.bat') -PathType Leaf)
}
function Get-ComfyUIRuntimeCoreFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$ChildItemReader = {
            param($DirectoryPath)
            Get-ChildItem -LiteralPath $DirectoryPath -Force `
                -ErrorAction Stop
        }
    )
    $rootItem = Get-Item -LiteralPath $Path -Force `
        -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        $rootItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
        throw 'ComfyUI runtime koku guvenli bir dizin degil.'
    }
    $root = [IO.Path]::GetFullPath($rootItem.FullName).
        TrimEnd('\')
    $rootPrefix = $root + '\'
    $excludedDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($relative in @(
        '.winlama',
        'ComfyUI\custom_nodes',
        'ComfyUI\input',
        'ComfyUI\output',
        'ComfyUI\temp',
        'ComfyUI\user',
        'python_embeded\Lib\site-packages',
        'python_embeded\Scripts',
        'WinlamaLogs'
    )) {
        $null = $excludedDirectories.Add($relative)
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(& $ChildItemReader $directory)) {
            if ($null -eq $item -or
                [string]::IsNullOrWhiteSpace(
                    [string]$item.FullName
                )) {
                throw 'ComfyUI runtime dizin kaydi gecersiz.'
            }
            $fullPath = [IO.Path]::GetFullPath(
                [string]$item.FullName
            )
            if (-not $fullPath.StartsWith(
                    $rootPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'ComfyUI runtime dizin siniri asildi.'
            }
            $attributes = [IO.FileAttributes]$item.Attributes
            if ($attributes -band
                [IO.FileAttributes]::ReparsePoint) {
                throw "ComfyUI runtime reparse noktasi iceriyor: $fullPath"
            }
            $relative = $fullPath.Substring($rootPrefix.Length)
            $isDirectory = [bool]$item.PSIsContainer -or
                $attributes -band [IO.FileAttributes]::Directory
            if ($isDirectory) {
                if ($excludedDirectories.Contains($relative) -or
                    [IO.Path]::GetFileName($fullPath) -ieq
                        '__pycache__') {
                    continue
                }
                $pending.Push($fullPath)
                continue
            }
            if ($relative -ieq '.winlama-runtime.json' -or
                $relative -ieq 'ComfyUI\extra_model_paths.yaml' -or
                $item.Extension -iin @('.pyc', '.pyo')) {
                continue
            }
            Write-Output $item
        }
    }
}
function Get-ComfyUIRuntimeCoreIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ComfyUIRuntimeCoreFiles -Path $root) {
        $relative = $file.FullName.Substring($root.Length).
            TrimStart('\')
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
function Test-ComfyUIRuntimeMarkerContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Marker,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$CoreIdentity
    )
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
function Test-ComfyUIRuntimeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    if (-not (Test-ComfyUIRuntimeLayout -Path $Path)) {
        return $false
    }
    $markerPath = Join-Path $Path '.winlama-runtime.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }
    try {
        $marker = Read-JsonFile -Path $markerPath
        $identity = Get-ComfyUIRuntimeCoreIdentity -Path $Path
        return Test-ComfyUIRuntimeMarkerContract `
            -Marker $marker -Config $Config `
            -CoreIdentity $identity
    }
    catch {
        Write-Verbose ('ComfyUI runtime kimligi dogrulanamadi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Assert-ComfyUIRuntimeIdentityContracts {
    [CmdletBinding()]
    param()
    $config = [pscustomobject]@{
        ComfyUI = [pscustomobject]@{
            PortableVersion = '0.32.0'
            PortableSha256 = 'A' * 64
            PortableSizeBytes = 2132254184
        }
    }
    $identity = [pscustomobject]@{
        FileCount = 3
        Sha256 = 'B' * 64
    }
    $current = [pscustomobject]@{
        SchemaVersion = 1
        PortableVersion = '0.32.0'
        ArchiveSha256 = 'A' * 64
        ArchiveSizeBytes = 2132254184
        CoreFileCount = 3
        CoreSha256 = 'B' * 64
    }
    $before = $current | ConvertTo-Json -Compress
    if (-not (Test-ComfyUIRuntimeMarkerContract `
        -Marker $current -Config $config `
        -CoreIdentity $identity)) {
        throw 'Guncel ComfyUI runtime kimligi reddedildi.'
    }
    foreach ($change in @(
        @{ Name = 'PortableVersion'; Value = '0.30.0' },
        @{ Name = 'ArchiveSha256'; Value = ('C' * 64) },
        @{ Name = 'ArchiveSizeBytes'; Value = 1 },
        @{ Name = 'CoreFileCount'; Value = 2 },
        @{ Name = 'CoreSha256'; Value = ('D' * 64) }
    )) {
        $bad = ConvertFrom-WinlamaJson -Json (
            ConvertTo-Json -InputObject $current -Depth 5
        )
        $bad.($change.Name) = $change.Value
        if (Test-ComfyUIRuntimeMarkerContract `
            -Marker $bad -Config $config `
            -CoreIdentity $identity) {
            throw 'Eski veya bozuk ComfyUI runtime kimligi kabul edildi.'
        }
    }
    if (($current | ConvertTo-Json -Compress) -cne $before) {
        throw 'ComfyUI runtime kimlik fixture girdisi degisti.'
    }
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('winlama-comfy-core-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    try {
        $readPaths = [Collections.Generic.List[string]]::new()
        $directoryReader = {
            param($DirectoryPath)
            $null = $readPaths.Add($DirectoryPath)
            $relative = if ($DirectoryPath -ieq $fixtureRoot) {
                ''
            }
            else {
                $DirectoryPath.Substring($fixtureRoot.Length + 1)
            }
            $children = switch ($relative) {
                '' { @('ComfyUI', 'python_embeded', '.winlama') }
                'ComfyUI' {
                    @('main.py', 'custom_nodes', 'user', 'input',
                        'output', 'temp', '__pycache__')
                }
                'python_embeded' { @('python.exe', 'Lib', 'Scripts') }
                'python_embeded\Lib' { @('site-packages') }
                default { @() }
            }
            foreach ($name in $children) {
                $childPath = Join-Path $DirectoryPath $name
                $isFile = $name -in @(
                    'main.py', 'python.exe'
                )
                [pscustomobject]@{
                    FullName = $childPath
                    PSIsContainer = -not $isFile
                    Attributes = if ($isFile) {
                        [IO.FileAttributes]::Normal
                    }
                    else {
                        [IO.FileAttributes]::Directory
                    }
                    Extension = if ($isFile) {
                        [IO.Path]::GetExtension($name)
                    }
                    else {
                        ''
                    }
                }
            }
        }.GetNewClosure()
        $files = @(Get-ComfyUIRuntimeCoreFiles `
            -Path $fixtureRoot -ChildItemReader $directoryReader)
        $forbiddenReads = @(
            '.winlama',
            'ComfyUI\custom_nodes',
            'ComfyUI\user',
            'ComfyUI\input',
            'ComfyUI\output',
            'ComfyUI\temp',
            'ComfyUI\__pycache__',
            'python_embeded\Lib\site-packages',
            'python_embeded\Scripts'
        ) | ForEach-Object { Join-Path $fixtureRoot $_ }
        if ($files.Count -ne 2 -or
            @($readPaths | Where-Object {
                $_ -iin $forbiddenReads
            }).Count -ne 0) {
            throw 'ComfyUI runtime agir agac budama sozlesmesi gecersiz.'
        }
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.RuntimeIdentity'
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.CoreTreePruning'
    return $true
}
function Get-ComfyUIRuntimeRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $installPath = [Environment]::ExpandEnvironmentVariables(
        [string]$Context.Config.ComfyUI.InstallPath
    )
    $runtimeRoot = [IO.Path]::GetFullPath($installPath)
    $launcher = Join-Path $runtimeRoot `
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
    $main = Join-Path $runtimeRoot 'ComfyUI\main.py'
    if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and
        (Test-Path -LiteralPath $main -PathType Leaf) -and
        (Test-ComfyUIRuntimeIdentity -Path $runtimeRoot `
            -Config $Context.Config)) {
        return $runtimeRoot
    }
    return $null
}
function Get-ComfyUILauncherPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $runtimeRoot = Get-ComfyUIRuntimeRoot -Context $Context
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        return $null
    }
    return Join-Path $runtimeRoot `
        'run_nvidia_gpu_fast_fp16_accumulation.bat'
}
function Stop-ComfyUIRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.ComfyUI.Enabled) {
        return
    }
    $runtimeRoot = Get-ComfyUIRuntimeRoot -Context $Context
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        return
    }
    Stop-ProcessesFromPath -RootPath $runtimeRoot `
        -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
}
function Get-ComfyUIHealthUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return 'http://127.0.0.1:{0}/object_info' -f `
        $Context.Config.ComfyUI.Port
}
function Get-ComfyUIObjectInfoRequirements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    $nodes = [Collections.Generic.List[string]]::new()
    $models = [Collections.Generic.List[string]]::new()
    foreach ($name in @($Config.ComfyUI.Requested)) {
        switch ([string]$name) {
            'FLUX.1-schnell' {
                foreach ($node in @(
                    'CheckpointLoaderSimple', 'CLIPTextEncode',
                    'EmptySD3LatentImage', 'KSampler', 'VAEDecode',
                    'SaveImage'
                )) {
                    if (-not $nodes.Contains($node)) {
                        $nodes.Add($node)
                    }
                }
                $models.Add('flux1-schnell-fp8.safetensors')
            }
            'Wan2.1-T2V-1.3B' {
                foreach ($node in @(
                    'CLIPLoader', 'CLIPTextEncode',
                    'LoadWanVideoT5TextEncoder', 'VHS_VideoCombine',
                    'WanVideoBlockSwap', 'WanVideoDecode',
                    'WanVideoEmptyEmbeds', 'WanVideoEnhanceAVideo',
                    'WanVideoLoraSelectMulti', 'WanVideoModelLoader',
                    'WanVideoSampler', 'WanVideoSetBlockSwap',
                    'WanVideoSetLoRAs', 'WanVideoTextEmbedBridge',
                    'WanVideoTextEncode',
                    'WanVideoTorchCompileSettings',
                    'WanVideoVAELoader'
                )) {
                    if (-not $nodes.Contains($node)) {
                        $nodes.Add($node)
                    }
                }
                foreach ($model in @(
                    'Wan2.1_T2V_1.3B.safetensors',
                    'models_t5_umt5-xxl-enc-bf16.pth',
                    'Wan2.1_VAE.pth'
                )) {
                    $models.Add($model)
                }
            }
        }
    }
    return [pscustomobject]@{
        Models = $models.ToArray()
        Nodes = $nodes.ToArray()
    }
}
function Test-ComfyUIObjectInfoContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ObjectInfo
    )
    if ($null -eq $ObjectInfo) {
        return $false
    }
    $requirements = Get-ComfyUIObjectInfoRequirements -Config $Config
    foreach ($node in @($requirements.Nodes)) {
        if ($null -eq $ObjectInfo.PSObject.Properties[$node]) {
            return $false
        }
    }
    $serialized = $ObjectInfo | ConvertTo-Json -Compress -Depth 50
    foreach ($model in @($requirements.Models)) {
        if ($serialized.IndexOf(
            $model,
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0) {
            return $false
        }
    }
    return $true
}
function Assert-ComfyUIObjectInfoContracts {
    [CmdletBinding()]
    param()
    $config = [pscustomobject]@{
        ComfyUI = [pscustomobject]@{
            Requested = @('FLUX.1-schnell')
        }
    }
    $nodes = @(
        'CheckpointLoaderSimple', 'CLIPTextEncode',
        'EmptySD3LatentImage', 'KSampler', 'VAEDecode', 'SaveImage'
    )
    $valid = [pscustomobject]@{}
    foreach ($node in $nodes) {
        $valid | Add-Member -NotePropertyName $node `
            -NotePropertyValue ([pscustomobject]@{
                input = @('flux1-schnell-fp8.safetensors')
            })
    }
    if (-not (Test-ComfyUIObjectInfoContract `
        -Config $config -ObjectInfo $valid)) {
        throw 'Gecerli ComfyUI object_info sozlesmesi reddedildi.'
    }
    $valid.PSObject.Properties.Remove('CheckpointLoaderSimple')
    if (Test-ComfyUIObjectInfoContract `
        -Config $config -ObjectInfo $valid) {
        throw 'Eksik ComfyUI dugumu kabul edildi.'
    }
    $missingModel = [pscustomobject]@{}
    foreach ($node in $nodes) {
        $missingModel | Add-Member -NotePropertyName $node `
            -NotePropertyValue ([pscustomobject]@{ input = @('other.ckpt') })
    }
    if (Test-ComfyUIObjectInfoContract `
        -Config $config -ObjectInfo $missingModel) {
        throw 'Eksik ComfyUI modeli kabul edildi.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ComfyUI.ObjectInfoContract'
}
function Test-ComfyUIReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.ComfyUI.Enabled) {
        return $true
    }
    try {
        $parameters = @{
            Uri = Get-ComfyUIHealthUri -Context $Context
            Method = 'Get'
            TimeoutSec = 5
        }
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $parameters.UseBasicParsing = $true
        }
        $objectInfo = Invoke-RestMethod @parameters
        return Test-ComfyUIObjectInfoContract `
            -Config $Context.Config -ObjectInfo $objectInfo
    }
    catch {
        Write-Verbose ('ComfyUI object_info hazir degil: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function New-ComfyUIChildPowerShellArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    return @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File',
        (ConvertTo-WindowsCommandLineArgument -Argument $ScriptPath),
        '-ConfigPath',
        (ConvertTo-WindowsCommandLineArgument -Argument $ConfigPath),
        '-NoPause', '-Background'
    )
}
function Start-ComfyUIInteractiveUserProcess {
    param([Parameter(Mandatory)][hashtable]$Start)
    $taskName = 'Winlama-ComfyUI-' + [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path `
        (Split-Path -Parent $Start.RedirectStandardOutput) "$taskName.json"
    $launch = @{ Parameters = $Start; ResultPath = $resultPath } |
        ConvertTo-Json -Depth 8 -Compress
    $payload = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($launch)
    )
    $command = '$payload = ''{0}''' -f $payload
    $command += [Environment]::NewLine + @'
$ErrorActionPreference = 'Stop'
$launch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
    ConvertFrom-Json -AsHashtable
$parameters = $launch.Parameters
try {
    $process = Start-Process @parameters
    $result = @{ ProcessId = $process.Id; Error = '' }
    $process.Dispose()
}
catch {
    $result = @{ ProcessId = 0; Error = $_.Exception.Message }
}
$temporary = $launch.ResultPath + '.tmp'
[IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Compress))
[IO.File]::Move($temporary, $launch.ResultPath)
'@
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )
    $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
        "-EncodedCommand $encoded"
    $action = New-ScheduledTaskAction -Execute $Start.FilePath `
        -Argument $arguments -WorkingDirectory $Start.WorkingDirectory
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal = New-ScheduledTaskPrincipal -UserId $sid `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $null = Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Settings $settings -ErrorAction Stop
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                Stop-ScheduledTask -TaskName $taskName `
                    -ErrorAction SilentlyContinue
                throw (Get-LocalizedText `
                    -Key 'Runtime.Error.ComfyUIUserLaunchTimeout')
            }
            Start-Sleep -Milliseconds 250
        }
        $result = Read-JsonFile -Path $resultPath
        if ([int]$result.ProcessId -le 0) {
            throw (Get-LocalizedText `
                -Key 'Runtime.Error.ComfyUIUserLaunchFailed' `
                -Arguments @([string]$result.Error))
        }
        $process = Get-Process -Id ([int]$result.ProcessId) -ErrorAction Stop
        if ($process.Path -ine $Start.FilePath) {
            $process.Dispose()
            throw (Get-LocalizedText `
                -Key 'Runtime.Error.ComfyUIUserLaunchFailed' `
                -Arguments @($Start.FilePath))
        }
        $null = $process.Handle
        return $process
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resultPath, "$resultPath.tmp" -Force `
            -ErrorAction SilentlyContinue
    }
}
function Start-ComfyUIRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$Mode = 'Keep',
        [switch]$Attached
    )
    if (-not $Context.Config.ComfyUI.Enabled -or $Mode -eq 'Skip') {
        return
    }
    $ready = Test-ComfyUIReady -Context $Context
    if ($ready -and $Mode -eq 'Keep') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module RUNTIME -Message 'Runtime.ComfyUI.AlreadyReady'
        return
    }
    Stop-ComfyUIRuntime -Context $Context
    if (Test-TcpEndpoint -HostName '127.0.0.1' `
        -Port ([int]$Context.Config.ComfyUI.Port)) {
        throw (Get-LocalizedText -Key 'Runtime.Error.ComfyUIListenerStillActive' `
            -Arguments @($Context.Config.ComfyUI.Port))
    }
    $scriptPath = @(
        (Join-Path $Context.AppPath 'Modules\UI\ComfyUI.ps1'),
        (Join-Path $Context.PackageRoot 'Modules\UI\ComfyUI.ps1')
    ) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw (Get-LocalizedText `
            -Key 'Runtime.Error.ComfyUIScriptMissing')
    }
    $configPath = @(
        (Join-Path $Context.AppPath 'Data\Configs\config.json'),
        (Join-Path $Context.PackageRoot 'Data\Configs\config.json')
    ) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFileMissing')
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module RUNTIME -Message 'Runtime.ComfyUI.Starting'
    $powershell = Get-PowerShellRuntimePath -Context $Context
    $launcher = Get-ComfyUILauncherPath -Context $Context
    if ([string]::IsNullOrWhiteSpace($launcher)) {
        throw (Get-LocalizedText `
            -Key 'Runtime.Error.ComfyUILauncherMissing')
    }
    $start = @{
        FilePath = $powershell
        ArgumentList = @(New-ComfyUIChildPowerShellArgumentList `
            -ScriptPath $scriptPath -ConfigPath $configPath)
        WorkingDirectory = Split-Path -Parent $launcher
        PassThru = $true
    }
    $errorPath = 'aktif terminal'
    if ($Attached) {
        $start.NoNewWindow = $true
    }
    else {
        $logDirectory = Join-Path `
            (Split-Path -Parent $launcher) 'WinlamaLogs'
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputPath = Join-Path $logDirectory "$stamp-cikti.log"
        $errorPath = Join-Path $logDirectory "$stamp-hata.log"
        $start.WindowStyle = 'Hidden'
        $start.RedirectStandardOutput = $outputPath
        $start.RedirectStandardError = $errorPath
    }
    $interactiveUserLaunch = -not $Attached -and
        [Environment]::UserInteractive -and (Test-IsAdministrator)
    $process = if ($interactiveUserLaunch) {
        Start-ComfyUIInteractiveUserProcess -Start $start
    }
    else {
        Start-Process @start
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(180)
    do {
        if (Test-ComfyUIReady -Context $Context) {
            $process.Dispose()
            Write-DeploymentLog -Context $Context -Level OK `
                -Module RUNTIME -Message 'Runtime.ComfyUI.Ready'
            return
        }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            $process.Dispose()
            throw (Get-LocalizedText `
                -Key 'Runtime.Error.ComfyUIExited' `
                -Arguments @($exitCode, $errorPath))
        }
        Start-Sleep -Seconds $Context.Config.Runtime.PollIntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Stop-ComfyUIRuntime -Context $Context
    if (-not $interactiveUserLaunch -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force `
            -ErrorAction SilentlyContinue
    }
    $process.Dispose()
    throw (Get-LocalizedText `
        -Key 'Runtime.Error.ComfyUIHealthTimeout' `
        -Arguments @($errorPath))
}
function Invoke-AiRuntimeAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Exception]]$Failures,
        [scriptblock]$FailureReporter,
        [switch]$Optional,
        [switch]$ContinueOnOptionalError
    )
    try {
        $null = & $Action
        return $true
    }
    catch {
        $exception = [InvalidOperationException]::new(
            ('{0}: {1}' -f $Name, $_.Exception.Message),
            $_.Exception
        )
        $degraded = $Optional -and $ContinueOnOptionalError
        if (-not $degraded) {
            $Failures.Add($exception)
        }
        if ($null -ne $FailureReporter) {
            $null = & $FailureReporter $Name $_ $degraded
        }
        return $false
    }
}
function Assert-AiRuntimeAggregateContracts {
    [CmdletBinding()]
    param()
    $null = Assert-OllamaRuntimeLaunchContracts
    $events = [Collections.Generic.List[string]]::new()
    $failures = [Collections.Generic.List[Exception]]::new()
    $null = Invoke-AiRuntimeAction -Name 'First' -Failures $failures `
        -Action { $events.Add('First') }
    $null = Invoke-AiRuntimeAction -Name 'Broken' -Failures $failures `
        -Action {
            $events.Add('Broken')
            throw 'fixture'
        }
    $null = Invoke-AiRuntimeAction -Name 'Last' -Failures $failures `
        -Action { $events.Add('Last') }
    if (($events -join ',') -ne 'First,Broken,Last' -or
        $failures.Count -ne 1 -or
        $failures[0].Message -notmatch '^Broken: fixture') {
        throw 'AI runtime hata toplama sozlesmesi gecersiz.'
    }
    $strictFailures = [Collections.Generic.List[Exception]]::new()
    $continuedFailures = [Collections.Generic.List[Exception]]::new()
    $coreFailures = [Collections.Generic.List[Exception]]::new()
    $reports = [Collections.Generic.List[string]]::new()
    $reporter = {
        param(
            [string]$Name,
            [Management.Automation.ErrorRecord]$Failure,
            [bool]$Degraded
        )
        $reports.Add(('{0}|{1}|{2}' -f `
            $Name, $Failure.Exception.Message, $Degraded))
    }
    $null = Invoke-AiRuntimeAction -Name 'Voice' `
        -Failures $strictFailures -Optional `
        -FailureReporter $reporter -Action { throw 'strict' }
    $null = Invoke-AiRuntimeAction -Name 'ComfyUI' `
        -Failures $continuedFailures -Optional `
        -ContinueOnOptionalError -FailureReporter $reporter `
        -Action { throw 'continued' }
    $null = Invoke-AiRuntimeAction -Name 'Open WebUI' `
        -Failures $coreFailures -ContinueOnOptionalError `
        -FailureReporter $reporter -Action { throw 'core' }
    $probeCounter = [pscustomobject]@{ Count = 0 }
    $disabledReady = Invoke-AiRuntimeHealthProbe -Enabled $false `
        -Degraded $false -Probe {
            $probeCounter.Count++
            return $false
        }
    $degradedReady = Invoke-AiRuntimeHealthProbe -Enabled $true `
        -Degraded $true -Probe {
            $probeCounter.Count++
            return $false
        }
    $enabledReady = Invoke-AiRuntimeHealthProbe -Enabled $true `
        -Degraded $false -Probe {
            $probeCounter.Count++
            return $true
        }
    $config = [pscustomobject]@{
        Installation = [pscustomobject]@{
            ContinueOnOptionalError = $true
        }
    }
    $context = [pscustomobject]@{ Config = $config }
    $configBefore = $config | ConvertTo-Json -Compress -Depth 5
    Set-AiRuntimeDegradedComponents -Context $context -Components @()
    Add-AiRuntimeDegradedComponent -Context $context -Name 'Voice'
    $durableState = [pscustomobject]@{ Count = 0; Json = '' }
    $durableConfig = [pscustomobject]@{
        Voice = [pscustomobject]@{ Enabled = $true }
        ComfyUI = [pscustomobject]@{ Enabled = $true }
    }
    $durableContext = [pscustomobject]@{ Config = $durableConfig }
    $durableWriter = {
        param([pscustomobject]$Value)
        $durableState.Count++
        $durableState.Json = ConvertTo-StableJson `
            -Value $Value -Depth 10
    }.GetNewClosure()
    Disable-AiRuntimeOptionalComponent -Context $durableContext `
        -Name Voice -ConfigWriter $durableWriter
    Disable-AiRuntimeOptionalComponent -Context $durableContext `
        -Name ComfyUI -ConfigWriter $durableWriter
    if ($durableState.Count -ne 2 -or
        [string]::IsNullOrWhiteSpace($durableState.Json)) {
        throw ('Opsiyonel runtime config yazici fiksturu gecersiz: ' +
            "Count=$($durableState.Count)")
    }
    $nextContextConfig = ConvertFrom-WinlamaJson `
        -Json $durableState.Json
    $disabledContext = [pscustomobject]@{
        Config = [pscustomobject]@{
            Ollama = [pscustomobject]@{ Enabled = $false }
            OpenWebUI = [pscustomobject]@{ Enabled = $false }
            Voice = [pscustomobject]@{ Enabled = $false }
            ComfyUI = [pscustomobject]@{ Enabled = $false }
        }
    }
    $strictContext = [pscustomobject]@{
        Config = [pscustomobject]@{
            Installation = [pscustomobject]@{
                ContinueOnOptionalError = $false
            }
        }
    }
    $childArguments = @(New-ComfyUIChildPowerShellArgumentList `
        -ScriptPath 'C:\Program Files\Winlama\Modules\UI\ComfyUI.ps1' `
        -ConfigPath 'D:\Winlama Data\config.json')
    $openWebUISource = (Get-Command Start-OpenWebUIRuntime `
        -ErrorAction Stop).Definition
    $ttsSource = (Get-Command Start-WinlamaTtsRuntime `
        -ErrorAction Stop).Definition
    $comfyUISource = (Get-Command Start-ComfyUIRuntime `
        -ErrorAction Stop).Definition
    if ($strictFailures.Count -ne 1 -or
        $continuedFailures.Count -ne 0 -or $coreFailures.Count -ne 1 -or
        $reports.Count -ne 3 -or
        $reports[0] -notlike 'Voice|strict|False' -or
        $reports[1] -notlike 'ComfyUI|continued|True' -or
        $reports[2] -notlike 'Open WebUI|core|False' -or
        -not $disabledReady -or -not $degradedReady -or
        -not $enabledReady -or $probeCounter.Count -ne 1 -or
        -not (Test-AiRuntimeComponentDegraded `
            -Context $context -Name 'Voice') -or
        (Test-AiRuntimeComponentDegraded `
            -Context $context -Name 'ComfyUI') -or
        -not (Test-AiRuntimeContinueOnOptionalError -Context $context) -or
        (Test-AiRuntimeContinueOnOptionalError -Context $strictContext) -or
        $durableState.Count -ne 2 -or
        $nextContextConfig.Voice.Enabled -or
        $nextContextConfig.ComfyUI.Enabled -or
        -not (Test-AiRuntimeComponentDegraded `
            -Context $durableContext -Name 'Voice') -or
        -not (Test-AiRuntimeComponentDegraded `
            -Context $durableContext -Name 'ComfyUI') -or
        -not (Test-AiRuntime -Context $disabledContext) -or
        -not (Test-OpenWebUIReady -Context $disabledContext) -or
        -not (Test-WinlamaTtsReady -Context $disabledContext) -or
        -not (Test-ComfyUIReady -Context $disabledContext) -or
        $childArguments.Count -ne 11 -or
        $childArguments[6] -cne
            '"C:\Program Files\Winlama\Modules\UI\ComfyUI.ps1"' -or
        $childArguments[8] -cne '"D:\Winlama Data\config.json"' -or
        $childArguments[9] -cne '-NoPause' -or
        $childArguments[10] -cne '-Background' -or
        $openWebUISource -notmatch "WindowStyle\s*=\s*'Hidden'" -or
        $ttsSource -notmatch "WindowStyle\s*=\s*'Hidden'" -or
        $comfyUISource -notmatch "WindowStyle\s*=\s*'Hidden'" -or
        $openWebUISource -match "WindowStyle\s*=\s*'Normal'" -or
        $ttsSource -match "WindowStyle\s*=\s*'Normal'" -or
        $comfyUISource -match "WindowStyle\s*=\s*'Normal'" -or
        ($config | ConvertTo-Json -Compress -Depth 5) -cne
            $configBefore) {
        throw 'AI runtime optional hata ve health sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.HealthMatrix'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.ChildArgumentQuoting'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.DetachedWindowsHidden'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.OptionalFailurePolicy'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.OptionalFailureDurable'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Runtime.AggregateContracts'
    return $true
}
function Start-AiRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$OllamaMode = 'Keep',
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$OpenWebUIMode = 'Keep',
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$VoiceMode = 'Keep',
        [ValidateSet('Keep', 'Restart', 'Skip')]
        [string]$ComfyUIMode = 'Keep',
        [switch]$Attached
    )
    Set-AiRuntimeDegradedComponents -Context $Context -Components @()
    $continueOptionalErrors =
        Test-AiRuntimeContinueOnOptionalError -Context $Context
    $failures = [Collections.Generic.List[Exception]]::new()
    $reportFailure = {
        param(
            [string]$Name,
            [Management.Automation.ErrorRecord]$Failure,
            [bool]$Degraded
        )
        $parameters = @{
            Context = $Context
            Level = if ($Degraded) { 'WARN' } else { 'ERROR' }
            Module = 'RUNTIME'
            Message = 'Runtime.Component.Failed'
            MessageArguments = @($Name, $Failure.Exception.Message)
            Exception = $Failure.Exception
        }
        if ($Degraded) {
            $parameters.Recovery = 'OPTIONAL_COMPONENT_DEGRADED'
        }
        Write-DeploymentLog @parameters
    }
    if ($OllamaMode -ne 'Skip' -and $Context.Config.Ollama.Enabled) {
        $null = Invoke-AiRuntimeAction -Name 'Ollama' `
            -Failures $failures -FailureReporter $reportFailure -Action {
                Start-OllamaApplication -Context $Context `
                    -Restart:($OllamaMode -eq 'Restart') -Attached:$Attached
            }
    }
    if ($OpenWebUIMode -ne 'Skip' -and
        $Context.Config.OpenWebUI.Enabled) {
        $null = Invoke-AiRuntimeAction -Name 'Open WebUI' `
            -Failures $failures -FailureReporter $reportFailure -Action {
                Start-OpenWebUIRuntime -Context $Context `
                    -Mode $OpenWebUIMode -Attached:$Attached
                if (Test-OpenWebUIDefaultConfigurationPending `
                    -Context $Context) {
                    Write-DeploymentLog -Context $Context -Level INFO `
                        -Module RUNTIME `
                        -Message 'Runtime.WebUI.DefaultConfigRestart'
                    Stop-OpenWebUIRuntime -Context $Context
                    Set-OpenWebUIEnvironment -Context $Context
                    $null = Import-OpenWebUIDefaultConfiguration `
                        -Context $Context
                    Start-OpenWebUIRuntime -Context $Context `
                        -Mode Restart -Attached:$Attached
                }
            }
    }
    if ($VoiceMode -ne 'Skip' -and $Context.Config.Voice.Enabled) {
        $voiceStarted = Invoke-AiRuntimeAction -Name 'Voice' `
            -Failures $failures -FailureReporter $reportFailure -Action {
                Start-WinlamaTtsRuntime -Context $Context `
                    -Mode $VoiceMode -Attached:$Attached
            } -Optional `
            -ContinueOnOptionalError:$continueOptionalErrors
        if (-not $voiceStarted -and $continueOptionalErrors) {
            Disable-AiRuntimeOptionalComponent `
                -Context $Context -Name Voice
        }
    }
    if ($ComfyUIMode -ne 'Skip' -and
        $Context.Config.ComfyUI.Enabled) {
        $comfyUIStarted = Invoke-AiRuntimeAction -Name 'ComfyUI' `
            -Failures $failures -FailureReporter $reportFailure -Action {
                Start-ComfyUIRuntime -Context $Context `
                    -Mode $ComfyUIMode -Attached:$Attached
            } -Optional `
            -ContinueOnOptionalError:$continueOptionalErrors
        if (-not $comfyUIStarted -and $continueOptionalErrors) {
            Disable-AiRuntimeOptionalComponent `
                -Context $Context -Name ComfyUI
        }
    }
    try {
        Set-AiRuntimePriority -Context $Context
    }
    catch {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module RUNTIME -Message 'Runtime.Priority.Failed' `
            -MessageArguments @($_.Exception.Message) `
            -Exception $_.Exception
    }
    if ($failures.Count -gt 0) {
        throw [AggregateException]::new(
            'Bir veya daha fazla AI bileseni baslatilamadi.',
            $failures.ToArray()
        )
    }
    Write-DeploymentLog -Context $Context -Level OK `
        -Module RUNTIME -Message 'Runtime.Ready'
}
function Stop-AiRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$IncludeOllama,
        [switch]$KeepOpenWebUI,
        [switch]$KeepVoice,
        [switch]$KeepComfyUI
    )
    if (-not $KeepComfyUI -and $Context.Config.ComfyUI.Enabled -and
        -not (Test-AiRuntimeComponentDegraded `
            -Context $Context -Name 'ComfyUI')) {
        Stop-ComfyUIRuntime -Context $Context
    }
    if (-not $KeepVoice -and $Context.Config.Voice.Enabled -and
        -not (Test-AiRuntimeComponentDegraded `
            -Context $Context -Name 'Voice')) {
        Stop-WinlamaTtsRuntime -Context $Context
    }
    if (-not $KeepOpenWebUI -and $Context.Config.OpenWebUI.Enabled) {
        Stop-OpenWebUIRuntime -Context $Context
    }
    if ($IncludeOllama -and $Context.Config.Ollama.Enabled) {
        Stop-ProcessesFromPath `
            -RootPath (Get-OllamaInstallPath -Context $Context) `
            -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
    }
}
function Test-AiRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not (Invoke-AiRuntimeHealthProbe `
        -Enabled ([bool]$Context.Config.Ollama.Enabled) `
        -Degraded $false `
        -Probe { Test-OllamaApiReady -Context $Context })) {
        return $false
    }
    if (-not (Invoke-AiRuntimeHealthProbe `
        -Enabled ([bool]$Context.Config.OpenWebUI.Enabled) `
        -Degraded $false `
        -Probe { Test-OpenWebUIReady -Context $Context })) {
        return $false
    }
    $continueOptionalErrors =
        Test-AiRuntimeContinueOnOptionalError -Context $Context
    $voiceReady = Invoke-AiRuntimeHealthProbe `
        -Enabled ([bool]$Context.Config.Voice.Enabled) `
        -Degraded (Test-AiRuntimeComponentDegraded `
            -Context $Context -Name 'Voice') `
        -Probe { Test-WinlamaTtsReady -Context $Context }
    if (-not $voiceReady) {
        if (-not $continueOptionalErrors) {
            return $false
        }
        Disable-AiRuntimeOptionalComponent `
            -Context $Context -Name Voice
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module RUNTIME -Message 'Runtime.Component.Failed' `
            -MessageArguments @('Voice', 'HEALTH_CHECK_FAILED') `
            -Recovery OPTIONAL_COMPONENT_DEGRADED
    }
    $comfyUIReady = Invoke-AiRuntimeHealthProbe `
        -Enabled ([bool]$Context.Config.ComfyUI.Enabled) `
        -Degraded (Test-AiRuntimeComponentDegraded `
            -Context $Context -Name 'ComfyUI') `
        -Probe { Test-ComfyUIReady -Context $Context }
    if (-not $comfyUIReady) {
        if (-not $continueOptionalErrors) {
            return $false
        }
        Disable-AiRuntimeOptionalComponent `
            -Context $Context -Name ComfyUI
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module RUNTIME -Message 'Runtime.Component.Failed' `
            -MessageArguments @('ComfyUI', 'HEALTH_CHECK_FAILED') `
            -Recovery OPTIONAL_COMPONENT_DEGRADED
    }
    return $true
}
Export-ModuleMember -Function @(
    'Stop-ProcessesFromPath', 'Assert-StopProcessesFromPathContracts',
    'Set-ProcessesFromPathPriority',
    'Set-AiRuntimePriority', 'Start-OllamaApplication',
    'Assert-OllamaRuntimeLaunchContracts',
    'Test-OpenWebUIReady',
    'Set-OpenWebUIEnvironment', 'Stop-OpenWebUIRuntime',
    'Start-OpenWebUIRuntime', 'Get-WinlamaTtsUri',
    'Test-WinlamaTtsHealthContract',
    'Assert-WinlamaTtsRuntimeContracts',
    'Test-WinlamaTtsReady', 'Stop-WinlamaTtsRuntime',
    'Start-WinlamaTtsRuntime', 'Get-ComfyUIHealthUri',
    'Get-ComfyUIObjectInfoRequirements',
    'Test-ComfyUIObjectInfoContract', 'Assert-ComfyUIObjectInfoContracts',
    'Test-ComfyUIRuntimeIdentity', 'Assert-ComfyUIRuntimeIdentityContracts',
    'Test-ComfyUIReady', 'Start-ComfyUIRuntime',
    'Invoke-AiRuntimeAction', 'Assert-AiRuntimeAggregateContracts',
    'Test-AiRuntimeComponentDegraded',
    'Start-AiRuntime',
    'Stop-AiRuntime', 'Test-AiRuntime'
)