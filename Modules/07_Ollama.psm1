Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Resolve-OllamaApplicationRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Candidates,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        }
    )
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $root = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($candidate)
            )
        }
        catch {
            continue
        }
        if (-not $seen.Add($root)) {
            continue
        }
        $cli = Join-Path $root 'ollama.exe'
        $application = Join-Path $root 'ollama app.exe'
        if ([bool](& $PathExists -Path $cli) -and
            [bool](& $PathExists -Path $application)) {
            return $root
        }
    }
    return $null
}
function Get-OllamaInstallPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $configured = [Environment]::ExpandEnvironmentVariables(
        $Context.Config.Ollama.InstallPath
    )
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add($configured)
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Ollama'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Ollama'))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Ollama'))
    }
    foreach ($cmd in @(Get-Command 'ollama.exe' `
            -CommandType Application -All `
            -ErrorAction SilentlyContinue)) {
        $candidates.Add((Split-Path -Parent $cmd.Source))
    }
    $resolved = Resolve-OllamaApplicationRoot `
        -Candidates $candidates.ToArray()
    if ($null -ne $resolved) {
        return $resolved
    }
    return [IO.Path]::GetFullPath($configured)
}
function Get-OllamaExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        },
        [scriptblock]$InstallPathResolver = {
            param($Value)
            Get-OllamaInstallPath -Context $Value
        }
    )
    $installPath = [string](& $InstallPathResolver $Context)
    $path = Join-Path $installPath 'ollama.exe'
    $application = Join-Path $installPath 'ollama app.exe'
    if ([bool](& $PathExists -Path $path) -and
        [bool](& $PathExists -Path $application)) {
        return [IO.Path]::GetFullPath($path)
    }
    throw (Get-LocalizedText -Key 'Ollama.Error.ExecutableMissing')
}
function Get-OllamaApplicationExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        },
        [scriptblock]$InstallPathResolver = {
            param($Value)
            Get-OllamaInstallPath -Context $Value
        }
    )
    $installPath = [string](& $InstallPathResolver $Context)
    $cli = Join-Path $installPath 'ollama.exe'
    $path = Join-Path $installPath 'ollama app.exe'
    if ([bool](& $PathExists -Path $cli) -and
        [bool](& $PathExists -Path $path)) {
        return [IO.Path]::GetFullPath($path)
    }
    throw (Get-LocalizedText `
        -Key 'Ollama.Error.ApplicationExecutableMissing')
}
function Get-OllamaApplicationArgumentList {
    [CmdletBinding()]
    param()
    return @('--hide', '--fast-startup')
}
function Test-OllamaApplicationRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [scriptblock]$PathExists,
        [scriptblock]$InstallPathResolver,
        [scriptblock]$ProcessReader = {
            Get-CimInstance -ClassName Win32_Process `
                -ErrorAction SilentlyContinue
        }
    )
    try {
        $application = if ($null -eq $PathExists) {
            if ($null -eq $InstallPathResolver) {
                Get-OllamaApplicationExecutable -Context $Context
            }
            else {
                Get-OllamaApplicationExecutable -Context $Context `
                    -InstallPathResolver $InstallPathResolver
            }
        }
        else {
            $parameters = @{
                Context = $Context
                PathExists = $PathExists
            }
            if ($null -ne $InstallPathResolver) {
                $parameters.InstallPathResolver = $InstallPathResolver
            }
            Get-OllamaApplicationExecutable @parameters
        }
        foreach ($process in @(& $ProcessReader)) {
            $property = $process.PSObject.Properties['ExecutablePath']
            if ($null -eq $property -or
                [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                continue
            }
            if ([IO.Path]::GetFullPath(
                [string]$property.Value
            ).Equals(
                $application,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                return $true
            }
        }
    }
    catch {
        Write-Verbose ('Ollama uygulama sureci denetlenemedi: {0}' -f `
            $_.Exception.Message)
    }
    return $false
}
function Assert-OllamaApplicationContracts {
    [CmdletBinding()]
    param()
    $root = [IO.Path]::GetFullPath('C:\Fixture\Ollama')
    $partialRoot = [IO.Path]::GetFullPath('C:\Fixture\Partial')
    $applicationOnlyRoot = [IO.Path]::GetFullPath(
        'C:\Fixture\ApplicationOnly'
    )
    $partialCli = Join-Path $partialRoot 'ollama.exe'
    $applicationOnly = Join-Path $applicationOnlyRoot 'ollama app.exe'
    $cli = Join-Path $root 'ollama.exe'
    $expected = Join-Path $root 'ollama app.exe'
    $context = [pscustomobject]@{
        Config = [pscustomobject]@{
            Ollama = [pscustomobject]@{ InstallPath = $root }
        }
    }
    $availableFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $null = $availableFiles.Add($partialCli)
    $null = $availableFiles.Add($applicationOnly)
    $null = $availableFiles.Add($cli)
    $null = $availableFiles.Add($expected)
    $pathTester = {
        param($Path)
        return $availableFiles.Contains([IO.Path]::GetFullPath($Path))
    }.GetNewClosure()
    $rootResolver = {
        param($Value)
        return $root
    }.GetNewClosure()
    $resolved = Get-OllamaApplicationExecutable -Context $context `
        -PathExists $pathTester -InstallPathResolver $rootResolver
    $resolvedCli = Get-OllamaExecutable -Context $context `
        -PathExists $pathTester -InstallPathResolver $rootResolver
    $resolvedRoot = Resolve-OllamaApplicationRoot `
        -Candidates @($partialRoot, $root) -PathExists $pathTester
    $partialRejected = $null -eq (Resolve-OllamaApplicationRoot `
        -Candidates @($partialRoot) -PathExists $pathTester)
    $partialExecutableRejected = $false
    try {
        $null = Get-OllamaExecutable -Context $context `
            -PathExists $pathTester -InstallPathResolver {
                return $partialRoot
            }.GetNewClosure()
    }
    catch {
        $partialExecutableRejected = $true
    }
    $applicationOnlyRejected = $false
    try {
        $null = Get-OllamaApplicationExecutable -Context $context `
            -PathExists $pathTester -InstallPathResolver {
                return $applicationOnlyRoot
            }.GetNewClosure()
    }
    catch {
        $applicationOnlyRejected = $true
    }
    $arguments = @(Get-OllamaApplicationArgumentList)
    $running = Test-OllamaApplicationRunning -Context $context `
        -PathExists $pathTester -InstallPathResolver $rootResolver `
        -ProcessReader {
            [pscustomobject]@{ ExecutablePath = $expected }
        }.GetNewClosure()
    $missingRejected = $false
    try {
        $null = Get-OllamaApplicationExecutable -Context $context `
            -PathExists { param($Path) $false } `
            -InstallPathResolver $rootResolver
    }
    catch {
        $missingRejected = $true
    }
    $resolverSource = (Get-Command Get-OllamaApplicationExecutable `
        -ErrorAction Stop).Definition
    $installPathSource = (Get-Command Get-OllamaInstallPath `
        -ErrorAction Stop).Definition
    if (-not $resolved.Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not [string]::Equals(
            $resolvedCli,
            $cli,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not [string]::Equals(
            $resolvedRoot,
            $root,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $partialRejected -or
        -not $partialExecutableRejected -or
        -not $applicationOnlyRejected -or
        ($arguments -join '|') -cne '--hide|--fast-startup' -or
        -not $running -or -not $missingRejected -or
        $resolverSource -match 'Get-OllamaExecutable' -or
        $installPathSource -notmatch
            '-CommandType\s+Application\s+-All') {
        throw 'Ollama tray uygulamasi sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Ollama.TrayApplication'
    return $true
}
function Get-OllamaBaseUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return 'http://{0}:{1}' -f $Context.Config.Ollama.ApiHost,
        $Context.Config.Ollama.Port
}
function Set-OllamaConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled) {
        return
    }
    $executable = Get-OllamaExecutable -Context $Context
    $application = Get-OllamaApplicationExecutable -Context $Context
    $null = Invoke-ExternalProcess -FilePath $executable `
        -ArgumentList @('--version') -TimeoutSeconds 30 `
        -Activity (Get-LocalizedText -Key 'Ollama.Process.VersionCheck')
    $origins = @(
        @($Context.Config.Ollama.AllowedOrigins) +
        @(Get-LocalHttpOrigins `
            -Port $Context.Config.OpenWebUI.Port `
            -IncludeNetwork:$Context.Config.Security.LanAccess) |
        Sort-Object -Unique
    )
    $Context.Config.Ollama.AllowedOrigins = $origins
    $values = [ordered]@{
        OLLAMA_HOST = '{0}:{1}' -f $Context.Config.Ollama.Host,
            $Context.Config.Ollama.Port
        OLLAMA_MODELS = $Context.ModelsPath
        OLLAMA_ORIGINS = $origins -join ','
    }
    $environmentChanged = $false
    foreach ($entry in $values.GetEnumerator()) {
        $current = [Environment]::GetEnvironmentVariable(
            $entry.Key,
            [EnvironmentVariableTarget]::User
        )
        if ($current -ne $entry.Value) {
            $environmentChanged = $true
        }
        [Environment]::SetEnvironmentVariable(
            $entry.Key,
            $entry.Value,
            [EnvironmentVariableTarget]::User
        )
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
    Send-EnvironmentChangedNotification
    $runtime = [pscustomobject][ordered]@{
        Executable = $executable
        Application = $application
        Host = $Context.Config.Ollama.Host
        ApiHost = $Context.Config.Ollama.ApiHost
        Port = $Context.Config.Ollama.Port
        ModelsPath = $Context.ModelsPath
        AllowedOrigins = $origins
        EnvironmentChanged = $environmentChanged
        ConfiguredAt = [DateTimeOffset]::UtcNow.ToString('O')
    }
    Write-AtomicTextFile `
        -Path (Join-Path $Context.DataPath 'ollama.runtime.json') `
        -Content (ConvertTo-StableJson -Value $runtime -Depth 10)
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module OLLAMA -Message 'Ollama.ApplicationConfigured'
}
function Test-OllamaConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled) {
        return $true
    }
    try {
        $runtimePath = Join-Path $Context.DataPath 'ollama.runtime.json'
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            return $false
        }
        $runtime = Read-JsonFile -Path $runtimePath
        if (-not (Test-Path -LiteralPath $runtime.Executable `
            -PathType Leaf) -or
            -not (Test-Path -LiteralPath $runtime.Application `
            -PathType Leaf)) {
            return $false
        }
        $expectedHost = '{0}:{1}' -f $Context.Config.Ollama.Host,
            $Context.Config.Ollama.Port
        $userHost = [Environment]::GetEnvironmentVariable(
            'OLLAMA_HOST',
            [EnvironmentVariableTarget]::User
        )
        $userModels = [Environment]::GetEnvironmentVariable(
            'OLLAMA_MODELS',
            [EnvironmentVariableTarget]::User
        )
        return $userHost -eq $expectedHost -and
            $userModels -eq $Context.ModelsPath
    }
    catch {
        Write-Verbose ('Ollama calisma durumu denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Invoke-OllamaApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory)]
        [string]$Path,
        [AllowNull()]
        [object]$Body,
        [int]$TimeoutSeconds = 120
    )
    $parameters = @{
        Uri = (Get-OllamaBaseUri -Context $Context) + $Path
        Method = $Method
        TimeoutSec = $TimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return Invoke-RestMethod @parameters
}
function Test-OllamaApiReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $uri = (Get-OllamaBaseUri -Context $Context) + '/api/version'
    return Test-HttpEndpoint -Uri $uri -TimeoutMilliseconds 5000
}
function Wait-OllamaReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-OllamaApiReady -Context $Context) {
            return Invoke-OllamaApi -Context $Context -Method GET `
                -Path '/api/version' -TimeoutSeconds 5
        }
        Start-Sleep -Seconds $Context.Config.Runtime.PollIntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw (Get-LocalizedText -Key 'Ollama.Error.HealthTimeout')
}
function Get-OllamaModelInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $response = Invoke-OllamaApi -Context $Context -Method GET `
        -Path '/api/tags' -TimeoutSeconds 30
    return @($response.models)
}
Export-ModuleMember -Function @(
    'Get-OllamaInstallPath', 'Get-OllamaExecutable',
    'Get-OllamaApplicationExecutable',
    'Get-OllamaApplicationArgumentList',
    'Test-OllamaApplicationRunning',
    'Assert-OllamaApplicationContracts', 'Get-OllamaBaseUri',
    'Set-OllamaConfiguration', 'Test-OllamaConfiguration',
    'Invoke-OllamaApi', 'Test-OllamaApiReady', 'Wait-OllamaReady',
    'Get-OllamaModelInventory'
)