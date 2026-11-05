Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-WingetExecutable {
    [CmdletBinding()]
    param()
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($null -ne $winget) {
        return $winget.Source
    }
    $package = Get-AppxPackage -AllUsers `
        -Name Microsoft.DesktopAppInstaller `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $package) {
        $manifest = Join-Path $package.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest `
                -ErrorAction SilentlyContinue
        }
        $packageExecutable = Join-Path $package.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $packageExecutable) {
            return $packageExecutable
        }
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA `
        'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $windowsApps) {
        return $windowsApps
    }
    return $null
}
function Get-StrictPythonVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $command = 'import struct,sys;' +
        'assert struct.calcsize("P")==8;' +
        'print("WINLAMA_PYTHON_VERSION="+' +
        '".".join(map(str,sys.version_info[:3])))'
    try {
        $result = Invoke-ExternalProcess -FilePath $Path `
            -ArgumentList @('-I', '-c', $command) -TimeoutSeconds 30
        $match = [regex]::Match(
            $result.StandardOutput,
            '(?m)^WINLAMA_PYTHON_VERSION=(?<Version>\d+\.\d+\.\d+)\s*$'
        )
        if (-not $match.Success) {
            return $null
        }
        return [version]$match.Groups['Version'].Value
    }
    catch {
        Write-Verbose ('Python surumu denetlenemedi: {0} | {1}' -f `
            $Path, $_.Exception.Message)
        return $null
    }
}
function Get-ExpectedWinlamaPythonRoot {
    [CmdletBinding()]
    param()
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw (New-NonRetryableException -Message `
            'LOCALAPPDATA bulunamadigi icin Python hedefi cozumlenemedi.')
    }
    $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).
        TrimEnd('\')
    if ($localAppData -cnotmatch '^[A-Za-z]:\\') {
        throw (New-NonRetryableException -Message `
            "Python hedefi yerel bir surucude degil: $localAppData")
    }
    return [IO.Path]::GetFullPath(
        (Join-Path $localAppData `
            'Programs\Winlama\Dependencies\Python311')
    ).TrimEnd('\')
}
function Get-PythonOwnedInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path
        },
        [scriptblock]$ItemReader = {
            param($Path)
            Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    )
    $property = $Dependency.PSObject.Properties['InstallPath']
    if ($Dependency.Name -cne 'Python' -or
        [string]$Dependency.WingetId -cne 'Python.Python.3.11' -or
        $null -eq $property -or
        [string]::IsNullOrWhiteSpace([string]$property.Value) -or
        [string]::IsNullOrWhiteSpace([string]$Context.RootPath)) {
        throw (New-NonRetryableException -Message `
            'Python kullanici hedefi yapilandirmasi eksik veya gecersiz.')
    }
    $expected = Get-ExpectedWinlamaPythonRoot
    $contextRoot = [IO.Path]::GetFullPath(
        [string]$Context.RootPath
    ).TrimEnd('\')
    $expectedContextRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama')
    ).TrimEnd('\')
    $configured = [Environment]::ExpandEnvironmentVariables(
        [string]$property.Value
    )
    if (-not [IO.Path]::IsPathRooted($configured)) {
        throw (New-NonRetryableException -Message `
            "Python hedefi mutlak degil: $configured")
    }
    $configured = [IO.Path]::GetFullPath($configured).TrimEnd('\')
    if (-not $contextRoot.Equals(
            $expectedContextRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $configured.Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (New-NonRetryableException -Message (
            'Python yalniz Winlama kullanici kokune kurulabilir. ' +
            "Beklenen: $expected | Bulunan: $configured"
        ))
    }
    $paths = @(
        [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\'),
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $expectedContextRoot,
        (Join-Path $expectedContextRoot 'Dependencies'),
        $expected
    )
    foreach ($path in $paths) {
        if (-not [bool](& $PathExists $path)) {
            continue
        }
        $item = & $ItemReader $path
        $attributes = [IO.FileAttributes]$item.Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw (New-NonRetryableException -Message `
                "Python hedef zinciri guvenli degil: $path")
        }
    }
    return $expected
}
function New-PythonInstallerLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [DateTimeOffset]$Timestamp = [DateTimeOffset]::MinValue,
        [string]$CorrelationId = ''
    )
    $expectedLogs = [IO.Path]::GetFullPath(
        (Join-Path ([string]$Context.RootPath) 'Logs')
    ).TrimEnd('\')
    $actualLogs = [IO.Path]::GetFullPath(
        [string]$Context.LogsPath
    ).TrimEnd('\')
    if (-not $actualLogs.Equals(
            $expectedLogs,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (New-NonRetryableException -Message `
            "Python kurucu gunluk dizini guvenli degil: $actualLogs")
    }
    if ($Timestamp -eq [DateTimeOffset]::MinValue) {
        $Timestamp = [DateTimeOffset]::UtcNow
    }
    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        $CorrelationId = [guid]::NewGuid().ToString('N')
    }
    if ($CorrelationId -cnotmatch '^[a-f0-9]{32}$') {
        throw (New-NonRetryableException -Message `
            'Python kurucu gunluk kimligi gecersiz.')
    }
    $name = 'python-install-{0}-{1}.log' -f `
        $Timestamp.UtcDateTime.ToString('yyyyMMddTHHmmssfffZ'),
        $CorrelationId
    return Join-Path $actualLogs $name
}
function New-PythonInstallerPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [string]$CorrelationId = '',
        [DateTimeOffset]$Timestamp = [DateTimeOffset]::MinValue,
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path
        },
        [scriptblock]$ItemReader = {
            param($Path)
            Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    )
    $required = @(
        '/quiet',
        'InstallAllUsers=0',
        'PrependPath=0',
        'AppendPath=0',
        'Include_launcher=0',
        'InstallLauncherAllUsers=0',
        'AssociateFiles=0',
        'Shortcuts=0',
        'Include_doc=0',
        'Include_tcltk=0',
        'Include_test=0',
        'Include_pip=1'
    )
    $configured = @($Dependency.InstallerArguments)
    if (($configured -join '|') -ine ($required -join '|')) {
        throw (New-NonRetryableException -Message `
            'Python kurucu argumanlari izolasyon sozlesmesine uymuyor.')
    }
    $root = Get-PythonOwnedInstallRoot -Dependency $Dependency `
        -Context $Context -PathExists $PathExists `
        -ItemReader $ItemReader
    $logPath = New-PythonInstallerLogPath -Context $Context `
        -Timestamp $Timestamp -CorrelationId $CorrelationId
    $arguments = @('/quiet', '/log', $logPath, "TargetDir=$root") +
        @($configured | Select-Object -Skip 1)
    return [pscustomobject][ordered]@{
        InstallRoot = $root
        LogPath = $logPath
        Arguments = $arguments
    }
}
function Get-PythonInstallerLogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return 'Kurucu gunlugu olusturulamadi.'
    }
    try {
        $evidence = @(Get-Content -LiteralPath $LogPath `
            -Tail 400 -ErrorAction Stop | Where-Object {
                $_ -match '(?i)(1603|0x[0-9a-f]+|error|fail|' +
                    'return value 3)'
            } | Select-Object -Last 8 | ForEach-Object {
                ([string]$_).Trim()
            })
        if ($evidence.Count -eq 0) {
            return 'Kurucu gunlugunde belirgin hata satiri bulunamadi.'
        }
        $text = $evidence -join ' || '
        if ($text.Length -gt 1200) {
            return $text.Substring(0, 1200)
        }
        return $text
    }
    catch {
        return "Kurucu gunlugu okunamadi: $($_.Exception.Message)"
    }
}
function New-PythonInstallerFailureException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Evidence
    )
    $message = if ($ExitCode -eq 1603) {
        Get-LocalizedText -Key 'Dependencies.Python.Error.Exit1603' `
            -Arguments @($InstallRoot, $LogPath, $Evidence)
    }
    else {
        Get-LocalizedText -Key 'Dependencies.Python.Error.ExitCode' `
            -Arguments @($ExitCode, $InstallRoot, $LogPath, $Evidence)
    }
    $exception = if ($ExitCode -eq 1618) {
        [InvalidOperationException]::new($message)
    }
    else {
        New-NonRetryableException -Message $message
    }
    $exception.Data['Winlama.InstallerExitCode'] = $ExitCode
    $exception.Data['Winlama.InstallerLogPath'] = $LogPath
    $exception.Data['Winlama.PythonInstallRoot'] = $InstallRoot
    return $exception
}
function Test-WingetInstallVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][bool]$DependencyVerified
    )
    return $ExitCode -in @(0, -1978335189) -and $DependencyVerified
}
function Get-PythonSupportedMinorTags {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Dependency)
    $minimum = [version][string]$Dependency.MinimumVersion
    $maximumProperty = $Dependency.PSObject.Properties[
        'MaximumVersionExclusive'
    ]
    if ($null -eq $maximumProperty -or
        [string]::IsNullOrWhiteSpace([string]$maximumProperty.Value)) {
        $target = [version][string]$Dependency.WingetVersion
        return @('{0}.{1}' -f $target.Major, $target.Minor)
    }
    $maximum = [version][string]$maximumProperty.Value
    $current = [version]::new($minimum.Major, $minimum.Minor, 0)
    $tags = [Collections.Generic.List[string]]::new()
    while ($current -lt $maximum -and $tags.Count -lt 32) {
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
    return @($tags)
}
function Get-PythonOfficialExecutableCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [AllowEmptyString()][string]$LocalAppData = $env:LOCALAPPDATA,
        [AllowEmptyString()][string]$ProgramFilesPath = $env:ProgramFiles
    )
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($tag in @(Get-PythonSupportedMinorTags `
            -Dependency $Dependency)) {
        $directory = 'Python{0}' -f $tag.Replace('.', '')
        if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) {
            $paths.Add((Join-Path $LocalAppData `
                "Programs\Python\$directory\python.exe"))
        }
        if (-not [string]::IsNullOrWhiteSpace($ProgramFilesPath)) {
            $paths.Add((Join-Path $ProgramFilesPath `
                "$directory\python.exe"))
        }
    }
    return @($paths)
}
function Get-PythonRegistryExecutableCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [string[]]$RegistryRoots = @(
            'HKCU:\Software\Python\PythonCore',
            'HKLM:\Software\Python\PythonCore'
        ),
        [scriptblock]$KeyReader = {
            param($Root)
            @(Get-ChildItem -LiteralPath $Root `
                -ErrorAction SilentlyContinue)
        },
        [scriptblock]$ValueReader = {
            param($Path)
            Get-ItemProperty -LiteralPath $Path `
                -ErrorAction SilentlyContinue
        }
    )
    $tags = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($tag in @(Get-PythonSupportedMinorTags `
            -Dependency $Dependency)) {
        [void]$tags.Add($tag)
    }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($root in $RegistryRoots) {
        foreach ($key in @(& $KeyReader $root)) {
            $tag = [string]$key.PSChildName
            $baseTag = ($tag -split '-', 2)[0]
            if (-not $tags.Contains($baseTag) -or
                $tag -match '(?i)-32$') {
                continue
            }
            $installPath = '{0}\InstallPath' -f `
                ([string]$key.PSPath).TrimEnd('\')
            $values = & $ValueReader $installPath
            if ($null -eq $values) {
                continue
            }
            $executableProperty = $values.PSObject.Properties[
                'ExecutablePath'
            ]
            if ($null -ne $executableProperty -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$executableProperty.Value
                )) {
                $paths.Add([string]$executableProperty.Value)
            }
            $defaultProperty = $values.PSObject.Properties['(default)']
            if ($null -eq $defaultProperty -or
                [string]::IsNullOrWhiteSpace(
                    [string]$defaultProperty.Value
                )) {
                continue
            }
            $registeredPath = [string]$defaultProperty.Value
            if ([IO.Path]::GetExtension($registeredPath) -ieq '.exe') {
                $paths.Add($registeredPath)
            }
            else {
                $paths.Add((Join-Path $registeredPath 'python.exe'))
            }
        }
    }
    return @($paths)
}
function Get-PythonCommandExecutableCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [scriptblock]$CommandReader = {
            param($Name)
            @(Get-Command -Name $Name -CommandType Application `
                -All -ErrorAction SilentlyContinue)
        }
    )
    $names = [Collections.Generic.List[string]]::new()
    $names.Add([string]$Dependency.Command)
    foreach ($tag in @(Get-PythonSupportedMinorTags `
            -Dependency $Dependency)) {
        $names.Add("python$tag.exe")
    }
    $names.Add('python3.exe')
    $seenNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or
            -not $seenNames.Add($name)) {
            continue
        }
        foreach ($command in @(& $CommandReader $name)) {
            if ($command -is [string]) {
                $paths.Add([string]$command)
                continue
            }
            foreach ($propertyName in @('Source', 'Path')) {
                $property = $command.PSObject.Properties[$propertyName]
                if ($null -ne $property -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$property.Value
                    )) {
                    $paths.Add([string]$property.Value)
                    break
                }
            }
        }
    }
    return @($paths)
}
function Add-PythonExecutableCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Candidates,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[string]]$Seen,
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][bool]$IsOwned,
        [Parameter(Mandatory)][string]$Source
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables(
            $Path.Trim().Trim('"')
        )
        $fullPath = [IO.Path]::GetFullPath($expanded)
        if ($fullPath.IndexOf('\Microsoft\WindowsApps\',
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return
        }
        if (-not $Seen.Add($fullPath)) {
            return
        }
        $Candidates.Add([pscustomobject][ordered]@{
            Path = $fullPath
            IsOwned = $IsOwned
            Source = $Source
        })
    }
    catch {
        Write-Verbose ('Python adayi gecersiz: {0} | {1}' -f `
            $Path, $_.Exception.Message)
    }
}
function Get-PythonExecutableCandidateRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    $root = Get-PythonOwnedInstallRoot -Dependency $Dependency `
        -Context $Context
    $candidates = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    Add-PythonExecutableCandidate -Candidates $candidates -Seen $seen `
        -Path (Join-Path $root 'python.exe') -IsOwned $true `
        -Source WinlamaOwned
    foreach ($path in @(Get-PythonOfficialExecutableCandidates `
            -Dependency $Dependency)) {
        Add-PythonExecutableCandidate -Candidates $candidates -Seen $seen `
            -Path $path -IsOwned $false -Source OfficialPath
    }
    foreach ($path in @(Get-PythonRegistryExecutableCandidates `
            -Dependency $Dependency)) {
        Add-PythonExecutableCandidate -Candidates $candidates -Seen $seen `
            -Path $path -IsOwned $false -Source Registry
    }
    foreach ($path in @(Get-PythonCommandExecutableCandidates `
            -Dependency $Dependency)) {
        Add-PythonExecutableCandidate -Candidates $candidates -Seen $seen `
            -Path $path -IsOwned $false -Source GetCommand
    }
    return @($candidates)
}
function Test-PythonCandidateVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][bool]$IsOwned
    )
    if ($Version -lt [version][string]$Dependency.MinimumVersion) {
        return $false
    }
    $maximum = $Dependency.PSObject.Properties[
        'MaximumVersionExclusive'
    ]
    if ($null -ne $maximum -and
        -not [string]::IsNullOrWhiteSpace([string]$maximum.Value) -and
        $Version -ge [version][string]$maximum.Value) {
        return $false
    }
    return -not $IsOwned -or
        $Version -eq [version][string]$Dependency.WingetVersion
}
function Resolve-PythonExecutableCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][object[]]$Candidates,
        [scriptblock]$VersionReader = {
            param($Path)
            Get-StrictPythonVersion -Path $Path
        }
    )
    foreach ($candidate in $Candidates) {
        $pathProperty = $candidate.PSObject.Properties['Path']
        $ownedProperty = $candidate.PSObject.Properties['IsOwned']
        if ($null -eq $pathProperty -or $null -eq $ownedProperty) {
            continue
        }
        $path = [string]$pathProperty.Value
        $version = & $VersionReader $path
        if ($null -eq $version -or
            -not (Test-PythonCandidateVersion -Dependency $Dependency `
                -Version ([version]$version) `
                -IsOwned ([bool]$ownedProperty.Value))) {
            continue
        }
        return [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($path)
            Version = [version]$version
            IsOwned = [bool]$ownedProperty.Value
            Source = [string]$candidate.Source
        }
    }
    return $null
}
function Get-PythonExecutableResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    return Resolve-PythonExecutableCandidate `
        -Dependency $Dependency `
        -Candidates @(Get-PythonExecutableCandidateRecords `
            -Dependency $Dependency -Context $Context)
}
function Test-PythonExecutableOwned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [AllowEmptyString()][string]$OwnedRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($OwnedRoot)) {
        $OwnedRoot = Get-PythonOwnedInstallRoot `
            -Dependency $Dependency -Context $Context
    }
    try {
        $expected = [IO.Path]::GetFullPath(
            (Join-Path $OwnedRoot 'python.exe')
        )
        $actual = [IO.Path]::GetFullPath($ExecutablePath)
        return $actual.Equals(
            $expected,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}
function Get-PythonDependencyAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$DependencyVerified,
        [Parameter(Mandatory)][bool]$ExecutableOwned,
        [Parameter(Mandatory)][bool]$OwnershipCurrent
    )
    return [pscustomobject][ordered]@{
        InstallRequired = -not $DependencyVerified
        RecordOwnership = $DependencyVerified -and
            $ExecutableOwned -and -not $OwnershipCurrent
    }
}
function Get-PythonExecutableCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    return @(Get-PythonExecutableCandidateRecords `
        -Dependency $Dependency -Context $Context | ForEach-Object Path)
}
function Resolve-OllamaDependencyExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Candidates,
        [scriptblock]$FileProbe = {
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
            $cli = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($candidate)
            )
        }
        catch {
            continue
        }
        if (-not $seen.Add($cli)) {
            continue
        }
        $application = Join-Path (Split-Path -Parent $cli) `
            'ollama app.exe'
        if ([bool](& $FileProbe -Path $cli) -and
            [bool](& $FileProbe -Path $application)) {
            return $cli
        }
    }
    return $null
}
function Get-DependencyExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [AllowNull()]
        [pscustomobject]$Context
    )
    if ([string]::IsNullOrWhiteSpace($Dependency.Command)) {
        return $null
    }
    if ($Dependency.Command -ceq 'python.exe') {
        $candidate = Get-PythonExecutableResolution `
            -Dependency $Dependency -Context $Context
        if ($null -eq $candidate) {
            return $null
        }
        return $candidate.Path
    }
    if ($Dependency.Command -ceq 'ollama.exe') {
        $ollamaCandidates = [Collections.Generic.List[string]]::new()
        if ($null -ne $Context -and
            $null -ne $Context.Config.Ollama -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$Context.Config.Ollama.InstallPath
            )) {
            $configured = [Environment]::ExpandEnvironmentVariables(
                [string]$Context.Config.Ollama.InstallPath
            )
            $ollamaCandidates.Add(
                (Join-Path $configured 'ollama.exe')
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $ollamaCandidates.Add((Join-Path $env:LOCALAPPDATA `
                'Programs\Ollama\ollama.exe'))
        }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $ollamaCandidates.Add((Join-Path $env:ProgramFiles `
                'Ollama\ollama.exe'))
        }
        if (-not [string]::IsNullOrWhiteSpace(
                ${env:ProgramFiles(x86)}
            )) {
            $ollamaCandidates.Add((Join-Path ${env:ProgramFiles(x86)} `
                'Ollama\ollama.exe'))
        }
        foreach ($cmd in @(Get-Command 'ollama.exe' `
                -CommandType Application -All `
                -ErrorAction SilentlyContinue)) {
            $ollamaCandidates.Add($cmd.Source)
        }
        return Resolve-OllamaDependencyExecutable `
            -Candidates $ollamaCandidates.ToArray()
    }
    return Resolve-ExecutablePath -Name $Dependency.Command `
        -AdditionalPaths @()
}
function Get-VisualCppRuntimeVersion {
    [CmdletBinding()]
    param()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($path in $paths) {
        $value = Get-ItemProperty -LiteralPath $path `
            -ErrorAction SilentlyContinue
        if ($null -ne $value -and $value.Installed -eq 1) {
            return Get-VersionFromText -Text ([string]$value.Version)
        }
    }
    return $null
}
function Get-DependencyVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [AllowNull()]
        [pscustomobject]$Context,
        [AllowEmptyString()]
        [string]$ExecutablePath = ''
    )
    if ($Dependency.Name -eq 'Visual C++ Runtime') {
        return Get-VisualCppRuntimeVersion
    }
    if ($Dependency.Command -ceq 'python.exe') {
        $candidate = Get-PythonExecutableResolution `
            -Dependency $Dependency -Context $Context
        if ($null -eq $candidate) {
            return $null
        }
        return $candidate.Version
    }
    $executable = if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        Get-DependencyExecutable -Dependency $Dependency -Context $Context
    }
    else {
        [IO.Path]::GetFullPath($ExecutablePath)
    }
    if ($null -eq $executable) {
        return $null
    }
    $arguments = @('--version')
    $timeoutSeconds = if ($Dependency.Command -ceq 'ollama.exe') { 90 } else { 30 }
    try {
        $result = Invoke-ExternalProcess -FilePath $executable `
            -ArgumentList $arguments -TimeoutSeconds $timeoutSeconds
        $text = "$($result.StandardOutput) $($result.StandardError)"
        return Get-VersionFromText -Text $text
    }
    catch {
        Write-Verbose ('Bagimlilik surumu denetlenemedi: {0} | {1}' -f `
            $Dependency.Name, $_.Exception.Message)
        return $null
    }
}
function Test-OllamaApplicationExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [scriptblock]$FileProbe
    )
    $applicationPath = Join-Path `
        (Split-Path -Parent $ExecutablePath) 'ollama app.exe'
    if ($null -ne $FileProbe) {
        return [bool](& $FileProbe -Path $applicationPath)
    }
    return Test-Path -LiteralPath $applicationPath -PathType Leaf
}
function Get-VerifiedDependencyVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [AllowNull()]
        [pscustomobject]$Context
    )
    $ollamaExecutable = ''
    if ($Dependency.Command -ceq 'ollama.exe') {
        $ollamaExecutable = Get-DependencyExecutable `
            -Dependency $Dependency -Context $Context
        if ($null -eq $ollamaExecutable -or
            -not (Test-OllamaApplicationExecutable `
                -ExecutablePath $ollamaExecutable)) {
            return $null
        }
    }
    $version = Get-DependencyVersion -Dependency $Dependency `
        -Context $Context -ExecutablePath $ollamaExecutable
    if ($null -eq $version -or $version -lt [version]$Dependency.MinimumVersion) {
        return $null
    }
    $maximumProperty = $Dependency.PSObject.Properties[
        'MaximumVersionExclusive'
    ]
    if ($null -ne $maximumProperty -and
        -not [string]::IsNullOrWhiteSpace($maximumProperty.Value) -and
        $version -ge [version]$maximumProperty.Value) {
        return $null
    }
    return $version
}
function Test-Dependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [AllowNull()]
        [pscustomobject]$Context
    )
    return $null -ne (Get-VerifiedDependencyVersion `
        -Dependency $Dependency -Context $Context)
}
function Install-DependencyWithWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WingetPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $scope = if ($null -ne $Dependency.PSObject.Properties['Scope']) {
        [string]$Dependency.Scope
    }
    else {
        'machine'
    }
    $arguments = @(
        'install', '--exact', '--id', $Dependency.WingetId,
        '--version', [string]$Dependency.WingetVersion,
        '--source', 'winget',
        '--silent', '--scope', $scope, '--force',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    return Invoke-ExternalProcess -FilePath $WingetPath `
        -ArgumentList $arguments `
        -TimeoutSeconds $Context.Config.Network.DownloadTimeoutSeconds `
        -AllowedExitCodes @(0, -1978335189)
}
function Install-DependencyFromOfflineArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $fileName = "$($Dependency.WingetId).exe"
    $requireSignature =
        $Context.Config.Security.RequireAuthenticodeForInstallers
    $path = Get-VerifiedArtifact -Descriptor $Dependency `
        -Context $Context -DestinationFileName $fileName `
        -RequireSignature:$requireSignature
    $artifactSource = 'OfficialHttpsArtifact'
    $offlineProperty = $Dependency.PSObject.Properties['OfflinePath']
    if ($null -ne $offlineProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$offlineProperty.Value
        )) {
        $offlinePath = Join-Path $Context.PackageRoot `
            ([string]$offlineProperty.Value)
        if ([IO.Path]::GetFullPath($path) -ieq
            [IO.Path]::GetFullPath($offlinePath)) {
            $artifactSource = 'LocalArtifact'
        }
    }
    $pythonPlan = $null
    if ($Dependency.Name -ceq 'Python') {
        $pythonPlan = New-PythonInstallerPlan `
            -Dependency $Dependency -Context $Context
        $arguments = @($pythonPlan.Arguments)
    }
    else {
        $argumentProperty = $Dependency.PSObject.Properties[
            'InstallerArguments'
        ]
        $arguments = @()
        if ($null -ne $argumentProperty) {
            $arguments = @($argumentProperty.Value)
        }
    }
    $allowedExitCodes = @(0, 1641, 3010)
    if ($null -ne $pythonPlan) {
        $allowedExitCodes += @(
            1601, 1602, 1603, 1605, 1618, 1619,
            1620, 1625, 1638, 1639, 1642, 5100
        )
    }
    $result = Invoke-ExternalProcess -FilePath $path `
        -ArgumentList $arguments `
        -TimeoutSeconds $Context.Config.Network.OperationTimeoutSeconds `
        -AllowedExitCodes $allowedExitCodes
    if ($null -ne $pythonPlan) {
        $result | Add-Member -NotePropertyName InstallerLogPath `
            -NotePropertyValue $pythonPlan.LogPath -Force
        $result | Add-Member -NotePropertyName InstallRoot `
            -NotePropertyValue $pythonPlan.InstallRoot -Force
        if ($result.ExitCode -notin @(0, 1641, 3010)) {
            $evidence = Get-PythonInstallerLogEvidence `
                -LogPath $pythonPlan.LogPath
            $streams = @(
                [string]$result.StandardError,
                [string]$result.StandardOutput
            ) | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
            if ($streams.Count -gt 0) {
                $evidence += ' | Surec ciktisi: ' +
                    (($streams -join ' | ').Trim())
            }
            throw (New-PythonInstallerFailureException `
                -ExitCode $result.ExitCode `
                -InstallRoot $pythonPlan.InstallRoot `
                -LogPath $pythonPlan.LogPath -Evidence $evidence)
        }
    }
    $result | Add-Member -NotePropertyName ArtifactSource `
        -NotePropertyValue $artifactSource -Force
    return $result
}
function Test-PythonOwnershipShouldBeRecorded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$WasPresent,
        [Parameter(Mandatory)][bool]$InstallerSucceeded,
        [Parameter(Mandatory)][bool]$DependencyVerified,
        [Parameter(Mandatory)][bool]$ExecutableOwned
    )
    return -not $WasPresent -and $InstallerSucceeded -and
        $DependencyVerified -and $ExecutableOwned
}
function Test-ArtifactSourceFallbackAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Local', 'Online')]
        [string]$InstallSource
    )
    return $InstallSource -ceq 'Automatic'
}
function New-PythonInstallOwnershipComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)]
        [ValidateSet(
            'LocalArtifact',
            'OfficialHttpsArtifact',
            'ExistingOwnedPath'
        )]
        [string]$Source,
        [Parameter(Mandatory)][DateTimeOffset]$InstalledAt
    )
    $expectedVersion = [version][string]$Dependency.WingetVersion
    $expectedRoot = Get-ExpectedWinlamaPythonRoot
    $fullRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $fullExecutable = [IO.Path]::GetFullPath($ExecutablePath)
    $expectedExecutable = [IO.Path]::GetFullPath(
        (Join-Path $expectedRoot 'python.exe')
    )
    if ($Dependency.Name -cne 'Python' -or
        [string]$Dependency.WingetId -cne 'Python.Python.3.11' -or
        $Version -ne $expectedVersion -or
        -not $fullRoot.Equals(
            $expectedRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $fullExecutable.Equals(
            $expectedExecutable,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Python kurulum sahipligi exact sozlesmeyle eslesmiyor.'
    }
    return [pscustomobject][ordered]@{
        OwnedByWinlama = $true
        PackageId = [string]$Dependency.WingetId
        Version = $Version.ToString()
        InstallScope = 'User'
        InstallRoot = $fullRoot
        ExecutablePath = $fullExecutable
        InstalledAt = $InstalledAt.ToUniversalTime().ToString('O')
        Source = $Source
    }
}
function Test-PythonInstallOwnershipCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [scriptblock]$DocumentReader = {
            param($Path)
            Read-JsonFile -Path $Path
        },
        [scriptblock]$PathExists = {
            param($Path)
            Test-Path -LiteralPath $Path
        },
        [scriptblock]$ItemReader = {
            param($Path)
            Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    )
    try {
        $path = Join-Path $Context.DataPath 'install-ownership.json'
        $document = & $DocumentReader $path
        $component = $document.Components.Python
        $root = Get-PythonOwnedInstallRoot -Dependency $Dependency `
            -Context $Context -PathExists $PathExists `
            -ItemReader $ItemReader
        $expectedExecutable = [IO.Path]::GetFullPath(
            (Join-Path $root 'python.exe')
        )
        $installedAt = [DateTimeOffset]::MinValue
        return [int]$document.SchemaVersion -eq 1 -and
            $component.OwnedByWinlama -is [bool] -and
            [bool]$component.OwnedByWinlama -and
            [string]$component.PackageId -ceq 'Python.Python.3.11' -and
            [version][string]$component.Version -eq
                [version][string]$Dependency.WingetVersion -and
            [string]$component.InstallScope -ceq 'User' -and
            [IO.Path]::GetFullPath(
                [string]$component.InstallRoot
            ).TrimEnd('\').Equals(
                $root,
                [StringComparison]::OrdinalIgnoreCase
            ) -and [IO.Path]::GetFullPath(
                [string]$component.ExecutablePath
            ).Equals(
                $expectedExecutable,
                [StringComparison]::OrdinalIgnoreCase
            ) -and [string]$component.Source -in @(
                'LocalArtifact',
                'OfficialHttpsArtifact',
                'ExistingOwnedPath'
            ) -and [DateTimeOffset]::TryParse(
                [string]$component.InstalledAt,
                [ref]$installedAt
            )
    }
    catch {
        return $false
    }
}
function Write-PythonInstallOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$Dependency,
        [Parameter(Mandatory)]
        [ValidateSet(
            'LocalArtifact',
            'OfficialHttpsArtifact',
            'ExistingOwnedPath'
        )]
        [string]$Source
    )
    $installRoot = Get-PythonOwnedInstallRoot `
        -Dependency $Dependency -Context $Context
    $resolution = Get-PythonExecutableResolution `
        -Dependency $Dependency -Context $Context
    if ($null -eq $resolution -or -not $resolution.IsOwned -or
        -not (Test-PythonExecutableOwned `
            -ExecutablePath $resolution.Path -Dependency $Dependency `
            -Context $Context)) {
        throw 'Kurulan Python sahiplik kimligi cozumlenemedi.'
    }
    $component = New-PythonInstallOwnershipComponent `
        -Dependency $Dependency -InstallRoot $installRoot `
        -ExecutablePath $resolution.Path `
        -Version $resolution.Version -Source $Source `
        -InstalledAt ([DateTimeOffset]::UtcNow)
    $path = Join-Path $Context.DataPath 'install-ownership.json'
    $document = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $candidate = Read-JsonFile -Path $path
            if ([int]$candidate.SchemaVersion -eq 1 -and
                $null -ne $candidate.PSObject.Properties['Components'] -and
                $candidate.Components -is [pscustomobject]) {
                $document = $candidate
            }
        }
        catch {
            Write-Verbose ('Eski sahiplik kaydi kullanilamadi: {0}' -f `
                $_.Exception.Message)
        }
    }
    if ($null -eq $document) {
        $document = [pscustomobject][ordered]@{
            SchemaVersion = 1
            Components = [pscustomobject][ordered]@{}
        }
    }
    if ($null -eq $document.Components) {
        $document.Components = [pscustomobject][ordered]@{}
    }
    $document.Components | Add-Member -NotePropertyName Python `
        -NotePropertyValue $component -Force
    Write-AtomicTextFile -Path $path `
        -Content (ConvertTo-StableJson -Value $document -Depth 10)
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module DEPENDENCIES `
        -Message 'Dependencies.PythonOwnership.Recorded' `
        -MessageArguments @($component.Version, $component.Source)
}
function Assert-DependencyOwnershipContracts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $configBefore = ConvertTo-StableJson -Value $Config -Depth 100
    $python = $Config.Dependencies | Where-Object Name -EQ 'Python' |
        Select-Object -First 1
    if ($null -eq $python) {
        throw 'Python sahiplik sozlesmesi icin bagimlilik yok.'
    }
    $ollamaExecutable = 'C:\Fixture\Ollama\ollama.exe'
    $ollamaApplication = 'C:\Fixture\Ollama\ollama app.exe'
    $ollamaApplicationPresent = Test-OllamaApplicationExecutable `
        -ExecutablePath $ollamaExecutable -FileProbe {
            param($Path)
            return $Path -ieq $ollamaApplication
        }.GetNewClosure()
    $ollamaApplicationMissing = Test-OllamaApplicationExecutable `
        -ExecutablePath $ollamaExecutable -FileProbe {
            param($Path)
            return $false
        }
    $staleOllamaCli = 'C:\Fixture\Path\ollama.exe'
    $completeOllamaCli = 'C:\Fixture\Configured\ollama.exe'
    $completeOllamaApplication =
        'C:\Fixture\Configured\ollama app.exe'
    $ollamaFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $null = $ollamaFiles.Add($staleOllamaCli)
    $null = $ollamaFiles.Add($completeOllamaCli)
    $null = $ollamaFiles.Add($completeOllamaApplication)
    $resolvedOllamaCli = Resolve-OllamaDependencyExecutable `
        -Candidates @($staleOllamaCli, $completeOllamaCli) `
        -FileProbe {
            param($Path)
            return $ollamaFiles.Contains(
                [IO.Path]::GetFullPath($Path)
            )
        }.GetNewClosure()
    $incompleteOllamaRejected = $null -eq (
        Resolve-OllamaDependencyExecutable `
            -Candidates @($staleOllamaCli) `
            -FileProbe {
                param($Path)
                return $ollamaFiles.Contains(
                    [IO.Path]::GetFullPath($Path)
                )
            }.GetNewClosure()
    )
    $dependencyProbe = (Get-Command Get-VerifiedDependencyVersion `
        -ErrorAction Stop).Definition
    $resolverProbe = (Get-Command Get-DependencyExecutable `
        -ErrorAction Stop).Definition
    if (-not $ollamaApplicationPresent -or
        $ollamaApplicationMissing -or
        -not $incompleteOllamaRejected -or
        -not [string]::Equals(
            $resolvedOllamaCli,
            $completeOllamaCli,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $dependencyProbe -notmatch 'Test-OllamaApplicationExecutable' -or
        $dependencyProbe -notmatch
            '-ExecutablePath\s+\$ollamaExecutable' -or
        $resolverProbe -notmatch 'Resolve-OllamaDependencyExecutable' -or
        $resolverProbe -notmatch '-CommandType\s+Application\s+-All') {
        throw 'Ollama uygulama bagimliligi sozlesmesi gecersiz.'
    }
    $strictProbe = (Get-Command Get-StrictPythonVersion `
        -ErrorAction Stop).Definition
    if (-not $strictProbe.Contains('struct.calcsize("P")==8')) {
        throw 'Python x64 mimari probe sozlesmesi gecersiz.'
    }
    $root = [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA 'Programs\Winlama')
    ).TrimEnd('\')
    $pythonRoot = Join-Path $root 'Dependencies\Python311'
    $context = [pscustomobject]@{
        Config = $Config
        RootPath = $root
        DataPath = Join-Path $root 'Data'
        LogsPath = Join-Path $root 'Logs'
    }
    $noPath = { param($Path) $false }
    $unusedItem = {
        param($Path)
        throw "Beklenmeyen fixture oge okuma cagrisi: $Path"
    }
    $officialCandidates = @(Get-PythonOfficialExecutableCandidates `
        -Dependency $python -LocalAppData 'C:\Fixture\User' `
        -ProgramFilesPath 'C:\Fixture\System')
    $expectedOfficial = @(
        'C:\Fixture\User\Programs\Python\Python311\python.exe',
        'C:\Fixture\System\Python311\python.exe',
        'C:\Fixture\User\Programs\Python\Python312\python.exe',
        'C:\Fixture\System\Python312\python.exe'
    )
    if (@($expectedOfficial | Where-Object {
                $_ -notin $officialCandidates
            }).Count -ne 0) {
        throw 'Python resmi yol kesif fixture sozlesmesi gecersiz.'
    }
    $registryExecutable = 'C:\Fixture\Registry\python.exe'
    $registryKey = [pscustomobject]@{
        PSChildName = '3.11'
        PSPath = 'Fixture:\PythonCore\3.11'
    }
    $registryKeyReader = {
        param($RegistryRoot)
        @($registryKey)
    }.GetNewClosure()
    $registryValueReader = {
        param($RegistryPath)
        [pscustomobject]@{
            ExecutablePath = $registryExecutable
            '(default)' = 'C:\Fixture\Registry'
        }
    }.GetNewClosure()
    $registryCandidates = @(
        Get-PythonRegistryExecutableCandidates -Dependency $python `
            -RegistryRoots @('Fixture:\PythonCore') `
            -KeyReader $registryKeyReader `
            -ValueReader $registryValueReader
    )
    if ($registryExecutable -notin $registryCandidates) {
        throw 'Python registry kesif fixture sozlesmesi gecersiz.'
    }
    $commandExecutable = 'C:\Fixture\Command\python.exe'
    $commandReader = {
        param($Name)
        if ($Name -ceq 'python.exe') {
            [pscustomobject]@{ Source = $commandExecutable }
        }
    }.GetNewClosure()
    $commandCandidates = @(Get-PythonCommandExecutableCandidates `
        -Dependency $python -CommandReader $commandReader)
    if ($commandExecutable -notin $commandCandidates) {
        throw 'Python Get-Command kesif fixture sozlesmesi gecersiz.'
    }
    $ownedExecutable = Join-Path $pythonRoot 'python.exe'
    $externalExecutable = 'C:\Fixture\External311\python.exe'
    $versions = @{
        $ownedExecutable = [version]'3.11.10'
        $externalExecutable = [version]'3.11.10'
    }
    $versionReader = {
        param($Path)
        $versions[$Path]
    }.GetNewClosure()
    $resolution = Resolve-PythonExecutableCandidate `
        -Dependency $python -Candidates @(
            [pscustomobject]@{
                Path = $ownedExecutable
                IsOwned = $true
                Source = 'WinlamaOwned'
            },
            [pscustomobject]@{
                Path = $externalExecutable
                IsOwned = $false
                Source = 'OfficialPath'
            }
        ) -VersionReader $versionReader
    if ($null -eq $resolution -or
        -not $resolution.Path.Equals(
            $externalExecutable,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-PythonCandidateVersion `
            -Dependency $python -Version ([version]'3.12.9') `
            -IsOwned $false) -or
        (Test-PythonCandidateVersion -Dependency $python `
            -Version ([version]'3.10.99') -IsOwned $false) -or
        (Test-PythonCandidateVersion -Dependency $python `
            -Version ([version]'3.13.0') -IsOwned $false) -or
        (Test-PythonCandidateVersion -Dependency $python `
            -Version ([version]'3.11.10') -IsOwned $true) -or
        -not (Test-PythonCandidateVersion -Dependency $python `
            -Version ([version][string]$python.WingetVersion) `
            -IsOwned $true)) {
        throw 'Python surum araligi fixture sozlesmesi gecersiz.'
    }
    $externalAction = Get-PythonDependencyAction `
        -DependencyVerified $true -ExecutableOwned $false `
        -OwnershipCurrent $false
    $ownedAction = Get-PythonDependencyAction `
        -DependencyVerified $true -ExecutableOwned $true `
        -OwnershipCurrent $false
    $missingAction = Get-PythonDependencyAction `
        -DependencyVerified $false -ExecutableOwned $false `
        -OwnershipCurrent $false
    if ($externalAction.InstallRequired -or
        $externalAction.RecordOwnership -or
        $ownedAction.InstallRequired -or
        -not $ownedAction.RecordOwnership -or
        -not $missingAction.InstallRequired -or
        $missingAction.RecordOwnership -or
        (Test-PythonExecutableOwned `
            -ExecutablePath $externalExecutable `
            -Dependency $python -Context $context `
            -OwnedRoot $pythonRoot) -or
        -not (Test-PythonExecutableOwned `
            -ExecutablePath $ownedExecutable `
            -Dependency $python -Context $context `
            -OwnedRoot $pythonRoot)) {
        throw 'Python harici kurulum eylem fixture sozlesmesi gecersiz.'
    }
    $planOne = New-PythonInstallerPlan -Dependency $python `
        -Context $context -PathExists $noPath `
        -ItemReader $unusedItem `
        -Timestamp ([DateTimeOffset]'2026-08-21T12:00:00Z') `
        -CorrelationId '00000000000000000000000000000001'
    $planTwo = New-PythonInstallerPlan -Dependency $python `
        -Context $context -PathExists $noPath `
        -ItemReader $unusedItem `
        -Timestamp ([DateTimeOffset]'2026-08-21T12:00:00Z') `
        -CorrelationId '00000000000000000000000000000002'
    $arguments = @($planOne.Arguments)
    if (-not $planOne.InstallRoot.Equals(
            $pythonRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $planOne.LogPath -ieq $planTwo.LogPath -or
        @($arguments | Where-Object { $_ -ceq '/log' }).Count -ne 1 -or
        @($arguments | Where-Object {
            $_ -ceq "TargetDir=$pythonRoot"
        }).Count -ne 1 -or 'InstallAllUsers=0' -notin $arguments -or
        'PrependPath=0' -notin $arguments -or
        'AppendPath=0' -notin $arguments -or
        'Include_launcher=0' -notin $arguments -or
        'InstallLauncherAllUsers=0' -notin $arguments -or
        'AssociateFiles=0' -notin $arguments -or
        'InstallAllUsers=1' -in $arguments -or
        'PrependPath=1' -in $arguments -or
        'AppendPath=1' -in $arguments) {
        throw 'Python izole kurulum plani sozlesmesi gecersiz.'
    }
    $component = New-PythonInstallOwnershipComponent `
        -Dependency $python -InstallRoot $pythonRoot `
        -ExecutablePath (Join-Path $pythonRoot 'python.exe') `
        -Version ([version][string]$python.WingetVersion) `
        -Source LocalArtifact `
        -InstalledAt ([DateTimeOffset]'2026-08-21T00:00:00Z')
    $document = [pscustomobject]@{
        SchemaVersion = 1
        Components = [pscustomobject]@{ Python = $component }
    }
    $documentReader = { param($Path) $document }.GetNewClosure()
    if (-not $component.OwnedByWinlama -or
        $component.PackageId -cne 'Python.Python.3.11' -or
        $component.Version -cne '3.11.9' -or
        $component.InstallScope -cne 'User' -or
        $component.Source -cne 'LocalArtifact' -or
        -not (Test-PythonInstallOwnershipCurrent `
            -Context $context -Dependency $python `
            -DocumentReader $documentReader -PathExists $noPath `
            -ItemReader $unusedItem) -or
        -not (Test-PythonOwnershipShouldBeRecorded `
            -WasPresent $false -InstallerSucceeded $true `
            -DependencyVerified $true -ExecutableOwned $true) -or
        (Test-PythonOwnershipShouldBeRecorded `
            -WasPresent $false -InstallerSucceeded $true `
            -DependencyVerified $true -ExecutableOwned $false) -or
        (Test-PythonOwnershipShouldBeRecorded `
            -WasPresent $true -InstallerSucceeded $true `
            -DependencyVerified $true -ExecutableOwned $true) -or
        (Test-PythonOwnershipShouldBeRecorded `
            -WasPresent $false -InstallerSucceeded $false `
            -DependencyVerified $true -ExecutableOwned $true)) {
        throw 'Python kurulum sahiplik sozlesmesi gecersiz.'
    }
    $outside = $python | Select-Object *
    $outside.InstallPath = 'C:\Python311'
    $outsideRejected = $false
    try {
        $null = New-PythonInstallerPlan -Dependency $outside `
            -Context $context -PathExists $noPath `
            -ItemReader $unusedItem `
            -CorrelationId '00000000000000000000000000000003'
    }
    catch {
        $outsideRejected = $_.Exception.Data['Winlama.Retryable'] -eq $false
    }
    $reparseRejected = $false
    try {
        $null = New-PythonInstallerPlan -Dependency $python `
            -Context $context -PathExists { param($Path) $true } `
            -ItemReader {
                param($Path)
                [pscustomobject]@{
                    Attributes = [IO.FileAttributes]::Directory -bor
                        [IO.FileAttributes]::ReparsePoint
                }
            } -CorrelationId '00000000000000000000000000000004'
    }
    catch {
        $reparseRejected = $_.Exception.Data['Winlama.Retryable'] -eq $false
    }
    if (-not $outsideRejected -or -not $reparseRejected) {
        throw 'Python hedef dizin guvenligi sozlesmesi gecersiz.'
    }
    $failure = New-PythonInstallerFailureException -ExitCode 1603 `
        -InstallRoot $pythonRoot -LogPath $planOne.LogPath `
        -Evidence 'Fixture Return value 3'
    $retryable = New-PythonInstallerFailureException -ExitCode 1618 `
        -InstallRoot $pythonRoot -LogPath $planOne.LogPath `
        -Evidence 'Fixture busy'
    $deterministic = New-PythonInstallerFailureException -ExitCode 1638 `
        -InstallRoot $pythonRoot -LogPath $planOne.LogPath `
        -Evidence 'Fixture already installed'
    if ($failure.Data['Winlama.Retryable'] -ne $false -or
        [int]$failure.Data['Winlama.InstallerExitCode'] -ne 1603 -or
        [string]$failure.Data['Winlama.InstallerLogPath'] -cne
            $planOne.LogPath -or
        $failure.Message -notmatch '1603' -or
        $failure.Message -notmatch [regex]::Escape($planOne.LogPath) -or
        $retryable.Data['Winlama.Retryable'] -eq $false -or
        $deterministic.Data['Winlama.Retryable'] -ne $false) {
        throw 'Python kurucu cikis politikasi sozlesmesi gecersiz.'
    }
    if ((Test-WingetInstallVerified -ExitCode 0 `
            -DependencyVerified $false) -or
        -not (Test-WingetInstallVerified -ExitCode 0 `
            -DependencyVerified $true) -or
        -not (Test-WingetInstallVerified -ExitCode -1978335189 `
            -DependencyVerified $true)) {
        throw 'Winget sonrasi dogrulama sozlesmesi gecersiz.'
    }
    if (-not (Test-ArtifactSourceFallbackAllowed `
            -InstallSource Automatic) -or
        (Test-ArtifactSourceFallbackAllowed -InstallSource Local) -or
        (Test-ArtifactSourceFallbackAllowed -InstallSource Online) -or
        (Test-ArtifactSourceFallbackAllowed -InstallSource automatic)) {
        throw 'Bagimlilik kaynak fallback sozlesmesi gecersiz.'
    }
    $platformSource = (Get-Command Install-PlatformDependencies `
        -ErrorAction Stop).Definition
    if ($platformSource.Contains('$localDependency') -or
        -not $platformSource.Contains(
            '-Dependency $dependency -Context $Context'
        )) {
        throw 'Automatic artifact fallback cagrisi Local yapildi.'
    }
    if ((ConvertTo-StableJson -Value $Config -Depth 100) -cne
        $configBefore) {
        throw 'Bagimlilik sozlesme fixture girdisi degisti.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Dependencies.SourceFallback'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Dependencies.AutomaticHttpsFallback'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Dependencies.PythonOwnership'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Dependencies.PythonDiscovery'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Dependencies.PythonIsolatedInstall'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Dependencies.PythonInstallerExitPolicy'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Dependencies.WingetVerification'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Dependencies.OllamaApplication'
}
function Get-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$DestinationFileName,
        [switch]$RequireSignature,
        [switch]$SuppressLog
    )
    $installSource = if ($null -ne $Descriptor.PSObject.Properties[
        'InstallSource'
    ]) {
        [string]$Descriptor.InstallSource
    }
    else {
        'Automatic'
    }
    if ($installSource -cnotin @('Automatic', 'Local', 'Online')) {
        throw [IO.InvalidDataException]::new(
            (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @(
                    "Dependencies.$($Descriptor.Name).InstallSource"
                ))
        )
    }
    $sourcePath = $null
    $usingLocalArtifact = $false
    if ($installSource -ne 'Online' -and
        $null -ne $Descriptor.PSObject.Properties['OfflinePath'] -and
        -not [string]::IsNullOrWhiteSpace($Descriptor.OfflinePath)) {
        $candidate = Join-Path $Context.PackageRoot `
            $Descriptor.OfflinePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $sourcePath = $candidate
            $usingLocalArtifact = $true
        }
    }
    $destination = Join-Path $Context.TempPath $DestinationFileName
    if ($null -eq $sourcePath) {
        if ($installSource -eq 'Local') {
            $message = Get-LocalizedText `
                -Key 'Dependencies.Error.LocalSourceMissing' `
                -Arguments @($Descriptor.OfflinePath)
            throw (New-NonRetryableException -Message $message)
        }
        if ([string]::IsNullOrWhiteSpace($Descriptor.Uri)) {
            throw (Get-LocalizedText `
                -Key 'Dependencies.Error.SourceMissing' `
                -Arguments @($DestinationFileName))
        }
        $uri = [uri]$Descriptor.Uri
        if ($uri.Scheme -ne 'https') {
            throw (Get-LocalizedText `
                -Key 'Dependencies.Error.HttpsRequired' `
                -Arguments @($uri))
        }
        Invoke-WebRequest -Uri $uri -OutFile $destination `
            -ConnectionTimeoutSeconds `
                $Context.Config.Network.ConnectTimeoutSeconds `
            -OperationTimeoutSeconds `
                $Context.Config.Network.DownloadTimeoutSeconds
        $sourcePath = $destination
    }
    try {
        $hash = [string]$Descriptor.Sha256
        if ($usingLocalArtifact -and
            $null -ne $Descriptor.PSObject.Properties[
                'OfflineSha256'
            ] -and -not [string]::IsNullOrWhiteSpace(
                [string]$Descriptor.OfflineSha256
            )) {
            $hash = [string]$Descriptor.OfflineSha256
        }
        $publisher = if ($null -ne $Descriptor.PSObject.Properties[
            'PublisherSubjectContains'
        ]) {
            [string]$Descriptor.PublisherSubjectContains
        }
        else {
            ''
        }
        $allowSignatureOnly = $usingLocalArtifact -and
            $RequireSignature -and
            $Context.Config.Security.
                AllowAuthenticodeOnlyForLocalInstallers -and
            -not [string]::IsNullOrWhiteSpace($publisher)
        if ($Context.Config.Security.RequireArtifactHashes -and
            [string]::IsNullOrWhiteSpace($hash) -and
            -not $allowSignatureOnly) {
            throw (Get-LocalizedText `
                -Key 'Dependencies.Error.HashMissing' `
                -Arguments @($DestinationFileName))
        }
        $actualHash = (Get-FileHash -LiteralPath $sourcePath `
            -Algorithm SHA256).Hash
        if (-not [string]::IsNullOrWhiteSpace($hash) -and
            $actualHash -ne $hash) {
            $message = Get-LocalizedText `
                -Key 'Dependencies.Error.HashFailed' `
                -Arguments @($DestinationFileName)
            if ($usingLocalArtifact) {
                throw (New-NonRetryableException -Message $message)
            }
            throw $message
        }
        $subject = ''
        if ($RequireSignature) {
            $signature = Get-AuthenticodeSignature -LiteralPath $sourcePath
            if ($signature.Status -ne 'Valid') {
                $message = Get-LocalizedText `
                    -Key 'Dependencies.Error.SignatureInvalid' `
                    -Arguments @($DestinationFileName)
                if ($usingLocalArtifact) {
                    throw (New-NonRetryableException -Message $message)
                }
                throw $message
            }
            $subject = [string]$signature.SignerCertificate.Subject
            if (-not [string]::IsNullOrWhiteSpace($publisher) -and
                $subject.IndexOf(
                    $publisher,
                    [StringComparison]::OrdinalIgnoreCase
                ) -lt 0) {
                $message = Get-LocalizedText `
                    -Key 'Dependencies.Error.PublisherInvalid' `
                    -Arguments @($DestinationFileName, $subject)
                if ($usingLocalArtifact) {
                    throw (New-NonRetryableException -Message $message)
                }
                throw $message
            }
        }
        if ($usingLocalArtifact -and -not $SuppressLog) {
            Write-DeploymentLog -Context $Context -Level OK `
                -Module DEPENDENCIES `
                -Message 'Dependencies.LocalArtifactVerified' `
                -MessageArguments @(
                    $Descriptor.Name,
                    $actualHash,
                    $subject
                )
        }
    }
    catch {
        if (-not $usingLocalArtifact -or
            -not (Test-ArtifactSourceFallbackAllowed `
                -InstallSource $installSource)) {
            if ($usingLocalArtifact -and $installSource -eq 'Local') {
                throw (New-NonRetryableException `
                    -Message $_.Exception.Message)
            }
            throw
        }
        if ($SuppressLog) {
            Write-Verbose ('Yerel artifact reddedildi; resmi kaynak ' +
                'kullanilacak: {0} | {1}' -f `
                $Descriptor.Name, $_.Exception.Message)
        }
        else {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module DEPENDENCIES `
                -Message 'Dependencies.LocalFailed' `
                -MessageArguments @($Descriptor.Name) `
                -Exception $_.Exception `
                -Recovery OFFICIAL_HTTPS_ARTIFACT
        }
        $onlineDescriptor = $Descriptor | Select-Object *
        $onlineDescriptor | Add-Member -NotePropertyName InstallSource `
            -NotePropertyValue Online -Force
        return Get-VerifiedArtifact -Descriptor $onlineDescriptor `
            -Context $Context `
            -DestinationFileName $DestinationFileName `
            -RequireSignature:$RequireSignature `
            -SuppressLog:$SuppressLog
    }
    return $sourcePath
}
function Install-PlatformDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $winget = $null
    $wingetResolved = $false
    foreach ($dependency in $Context.Config.Dependencies) {
        if (-not [bool]$dependency.Required) {
            continue
        }
        $pythonAction = $null
        $pythonExecutable = ''
        $pythonResolution = $null
        if ($dependency.Name -ceq 'Python') {
            $pythonResolution = Get-PythonExecutableResolution `
                -Dependency $dependency -Context $Context
            $pythonVerified = $null -ne $pythonResolution
            $pythonOwned = $false
            $ownershipCurrent = $false
            if ($pythonVerified) {
                $pythonExecutable = [string]$pythonResolution.Path
                $pythonOwned = Test-PythonExecutableOwned `
                    -ExecutablePath $pythonExecutable `
                    -Dependency $dependency -Context $Context
            }
            if ($pythonOwned) {
                $ownershipCurrent = Test-PythonInstallOwnershipCurrent `
                    -Context $Context -Dependency $dependency
            }
            $pythonAction = Get-PythonDependencyAction `
                -DependencyVerified $pythonVerified `
                -ExecutableOwned $pythonOwned `
                -OwnershipCurrent $ownershipCurrent
            $wasPresent = -not $pythonAction.InstallRequired
        }
        else {
            $wasPresent = Test-Dependency -Dependency $dependency `
                -Context $Context
        }
        if ($wasPresent) {
            if ($null -ne $pythonAction -and
                $pythonAction.RecordOwnership) {
                Write-PythonInstallOwnership -Context $Context `
                    -Dependency $dependency -Source ExistingOwnedPath
            }
            Write-DeploymentLog -Context $Context -Level INFO `
                -Module DEPENDENCIES `
                -Message 'Dependencies.Verified' `
                -MessageArguments @($dependency.Name)
            continue
        }
        $installed = $false
        $installerSucceeded = $false
        $verifiedVersion = $null
        $ownershipSource = ''
        $installSource = if ($null -ne $dependency.PSObject.Properties[
            'InstallSource'
        ]) {
            [string]$dependency.InstallSource
        }
        else {
            'Automatic'
        }
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module DEPENDENCIES `
            -Message 'Dependencies.Installing' `
            -MessageArguments @($dependency.Name)
        $offlinePath = if ($null -ne $dependency.PSObject.Properties[
            'OfflinePath'
        ]) {
            Join-Path $Context.PackageRoot `
                ([string]$dependency.OfflinePath)
        }
        else {
            ''
        }
        if ($installSource -ne 'Online' -and
            -not [string]::IsNullOrWhiteSpace($offlinePath) -and
            (Test-Path -LiteralPath $offlinePath -PathType Leaf)) {
            try {
                $installResult = `
                    Install-DependencyFromOfflineArtifact `
                    -Dependency $dependency -Context $Context
                $installerSucceeded = $installResult.ExitCode -in `
                    @(0, 1641, 3010)
                $ownershipSource = if ($null -ne
                    $installResult.PSObject.Properties['ArtifactSource']) {
                    [string]$installResult.ArtifactSource
                }
                else {
                    'LocalArtifact'
                }
                Sync-SystemEnvironment -Context $Context
                $verifiedVersion = Get-VerifiedDependencyVersion `
                    -Dependency $dependency -Context $Context
                $installed = $null -ne $verifiedVersion
                if (-not $installed) {
                    $message = Get-LocalizedText `
                        -Key 'Dependencies.Error.VerificationFailed' `
                        -Arguments @($dependency.Name)
                    if ($dependency.Name -ceq 'Python') {
                        throw (New-NonRetryableException -Message $message)
                    }
                    throw $message
                }
            }
            catch {
                $installerSucceeded = $false
                $verifiedVersion = $null
                $ownershipSource = ''
                if ($_.Exception.Data['Winlama.Retryable'] -eq $false -or
                    $installSource -eq 'Local') {
                    throw
                }
                Write-DeploymentLog -Context $Context -Level WARN `
                    -Module DEPENDENCIES `
                    -Message 'Dependencies.LocalFailed' `
                    -MessageArguments @($dependency.Name) `
                    -Exception $_.Exception -Recovery WINGET_OR_OFFICIAL
            }
        }
        elseif ($installSource -eq 'Local') {
            throw (New-NonRetryableException -Message (
                Get-LocalizedText `
                    -Key 'Dependencies.Error.LocalSourceMissing' `
                    -Arguments @($dependency.OfflinePath)
            ))
        }
        if (-not $installed -and
            $dependency.Name -cne 'Python' -and
            $installSource -ne 'Local' -and
            -not $wingetResolved) {
            $winget = Get-WingetExecutable
            $wingetResolved = $true
        }
        if (-not $installed -and
            $dependency.Name -cne 'Python' -and
            $null -ne $winget -and
            $installSource -ne 'Local') {
            try {
                $installResult = Install-DependencyWithWinget `
                    -WingetPath $winget `
                    -Dependency $dependency -Context $Context
                Sync-SystemEnvironment -Context $Context
                $verifiedVersion = Get-VerifiedDependencyVersion `
                    -Dependency $dependency -Context $Context
                $installerSucceeded = Test-WingetInstallVerified `
                    -ExitCode $installResult.ExitCode `
                    -DependencyVerified ($null -ne $verifiedVersion)
                $installed = $installerSucceeded
                if (-not $installed) {
                    throw (Get-LocalizedText `
                        -Key 'Dependencies.Error.VerificationFailed' `
                        -Arguments @($dependency.Name))
                }
                $ownershipSource = 'Winget'
            }
            catch {
                $installerSucceeded = $false
                $verifiedVersion = $null
                $ownershipSource = ''
                Write-DeploymentLog -Context $Context -Level WARN `
                    -Module DEPENDENCIES `
                    -Message 'Dependencies.WingetFailed' `
                    -MessageArguments @($dependency.Name) `
                    -Exception $_.Exception -Recovery VERIFIED_ARTIFACT
            }
        }
        if (-not $installed -and $installSource -ne 'Local') {
            $onlineDependency = $dependency | Select-Object *
            $onlineDependency | Add-Member `
                -NotePropertyName InstallSource `
                -NotePropertyValue 'Online' -Force
            $installResult = Install-DependencyFromOfflineArtifact `
                -Dependency $onlineDependency -Context $Context
            $installerSucceeded = $installResult.ExitCode -in `
                @(0, 1641, 3010)
            $ownershipSource = if ($null -ne
                $installResult.PSObject.Properties['ArtifactSource']) {
                [string]$installResult.ArtifactSource
            }
            else {
                'OfficialHttpsArtifact'
            }
        }
        Sync-SystemEnvironment -Context $Context
        $pythonExecutableOwned = $false
        if ($dependency.Name -ceq 'Python') {
            $pythonResolution = Get-PythonExecutableResolution `
                -Dependency $dependency -Context $Context
            $dependencyVerified = $null -ne $pythonResolution
            if ($dependencyVerified) {
                $pythonExecutable = [string]$pythonResolution.Path
                $pythonExecutableOwned = Test-PythonExecutableOwned `
                    -ExecutablePath $pythonExecutable `
                    -Dependency $dependency -Context $Context
            }
        }
        else {
            if ($null -eq $verifiedVersion) {
                $verifiedVersion = Get-VerifiedDependencyVersion `
                    -Dependency $dependency -Context $Context
            }
            $dependencyVerified = $null -ne $verifiedVersion
        }
        if (-not $dependencyVerified) {
            $message = Get-LocalizedText `
                -Key 'Dependencies.Error.VerificationFailed' `
                -Arguments @($dependency.Name)
            if ($installSource -eq 'Local' -or
                $dependency.Name -ceq 'Python') {
                throw (New-NonRetryableException -Message $message)
            }
            throw $message
        }
        if ($dependency.Name -ceq 'Python' -and
            (Test-PythonOwnershipShouldBeRecorded `
                -WasPresent $wasPresent `
                -InstallerSucceeded $installerSucceeded `
                -DependencyVerified $dependencyVerified `
                -ExecutableOwned $pythonExecutableOwned)) {
            Write-PythonInstallOwnership -Context $Context `
                -Dependency $dependency -Source $ownershipSource
        }
        $version = if ($dependency.Name -ceq 'Python') {
            $pythonResolution.Version
        }
        else {
            $verifiedVersion
        }
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module DEPENDENCIES `
            -Message 'Dependencies.Ready' `
            -MessageArguments @($dependency.Name, $version)
    }
}
function Test-PlatformDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    foreach ($dependency in $Context.Config.Dependencies) {
        if ($dependency.Required -and
            -not (Test-Dependency -Dependency $dependency `
                -Context $Context)) {
            return $false
        }
    }
    return $true
}
Export-ModuleMember -Function @(
    'Get-WingetExecutable', 'Get-StrictPythonVersion',
    'Get-PythonExecutableCandidates', 'Get-DependencyExecutable',
    'Get-DependencyVersion', 'Test-Dependency',
    'Install-PlatformDependencies', 'Test-PlatformDependencies',
    'Get-VerifiedArtifact', 'Test-PythonOwnershipShouldBeRecorded',
    'New-PythonInstallOwnershipComponent',
    'Assert-DependencyOwnershipContracts'
)