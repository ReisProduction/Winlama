Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Resolve-ExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string[]]$AdditionalPaths = @()
    )
    $command = Get-Command $Name -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }
    foreach ($path in $AdditionalPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [IO.Path]::GetFullPath($path)
        }
    }
    return $null
}
function Get-ExternalProcessActivity {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $name = [IO.Path]::GetFileName($FilePath)
    if ($name -iin @('pwsh.exe', 'powershell.exe')) {
        $fileIndex = [Array]::IndexOf($ArgumentList, '-File')
        if ($fileIndex -ge 0 -and
            $fileIndex + 1 -lt $ArgumentList.Count) {
            return Get-LocalizedText `
                -Key 'Process.PowerShell.Script' `
                -Arguments @(
                    [IO.Path]::GetFileName(
                        $ArgumentList[$fileIndex + 1]
                    )
                )
        }
        return Get-LocalizedText -Key 'Process.PowerShell.Command'
    }
    if ($name -imatch '^python(?:w)?\.exe$') {
        if ($ArgumentList -contains '-m' -and
            $ArgumentList -contains 'pip') {
            return Get-LocalizedText `
                -Key 'Process.Python.PackageOperation'
        }
        if ($ArgumentList -contains '-m' -and
            $ArgumentList -contains 'venv') {
            return Get-LocalizedText `
                -Key 'Process.Python.EnvironmentOperation'
        }
        return Get-LocalizedText -Key 'Process.Python.Validation'
    }
    if ($name -ieq 'ollama.exe') {
        $pullIndex = [Array]::IndexOf($ArgumentList, 'pull')
        if ($pullIndex -ge 0 -and
            $pullIndex + 1 -lt $ArgumentList.Count) {
            return Get-LocalizedText -Key 'Process.Ollama.Pull' `
                -Arguments @($ArgumentList[$pullIndex + 1])
        }
        return Get-LocalizedText -Key 'Process.Ollama.Command'
    }
    if ($name -ieq 'nvidia-smi.exe') {
        return Get-LocalizedText -Key 'Process.Nvidia.Inventory'
    }
    if ($name -ieq 'winget.exe') {
        return Get-LocalizedText -Key 'Process.Winget.Operation'
    }
    if ($name -ieq 'shutdown.exe') {
        return Get-LocalizedText -Key 'Process.System.Reboot'
    }
    if ($name -ieq 'icacls.exe') {
        return Get-LocalizedText -Key 'Process.Permissions.Apply'
    }
    return Get-LocalizedText -Key 'Process.Executable.Command' `
        -Arguments @($name)
}
function Wait-ExternalProcessOutputTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Threading.Tasks.Task[]]$Tasks,
        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds
    )
    if ($Tasks.Count -eq 0) {
        return $true
    }
    try {
        return [Threading.Tasks.Task]::WaitAll(
            $Tasks,
            $TimeoutMilliseconds
        )
    }
    catch {
        return $false
    }
}
function Get-ExternalNativeProcessInventory {
    [CmdletBinding()]
    param()
    $nativeType = 'Winlama.NativeProcessTree' -as [type]
    if ($null -eq $nativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Winlama
{
    public static class NativeProcessTree
    {
        private const uint SnapshotProcesses = 0x00000002;
        private const int NoMoreFiles = 18;
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ProcessEntry
        {
            public uint Size;
            public uint Usage;
            public uint ProcessId;
            public IntPtr DefaultHeapId;
            public uint ModuleId;
            public uint Threads;
            public uint ParentProcessId;
            public int PriorityClassBase;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string ExecutableName;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(
            uint flags,
            uint processId);
        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern bool Process32FirstW(
            IntPtr snapshot,
            ref ProcessEntry entry);
        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern bool Process32NextW(
            IntPtr snapshot,
            ref ProcessEntry entry);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        public static int[][] GetInventory()
        {
            var snapshot = CreateToolhelp32Snapshot(
                SnapshotProcesses,
                0);
            if (snapshot == new IntPtr(-1))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error());
            }
            try
            {
                var result = new List<int[]>();
                var entry = new ProcessEntry();
                entry.Size = (uint)Marshal.SizeOf(
                    typeof(ProcessEntry));
                if (!Process32FirstW(snapshot, ref entry))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == NoMoreFiles)
                    {
                        return result.ToArray();
                    }
                    throw new Win32Exception(error);
                }
                do
                {
                    result.Add(new int[]
                    {
                        (int)entry.ProcessId,
                        (int)entry.ParentProcessId
                    });
                    entry.Size = (uint)Marshal.SizeOf(
                        typeof(ProcessEntry));
                }
                while (Process32NextW(snapshot, ref entry));
                var finalError = Marshal.GetLastWin32Error();
                if (finalError != NoMoreFiles)
                {
                    throw new Win32Exception(finalError);
                }
                return result.ToArray();
            }
            finally
            {
                CloseHandle(snapshot);
            }
        }
    }
}
'@ -ErrorAction Stop
        $nativeType = 'Winlama.NativeProcessTree' -as [type]
    }
    if ($null -eq $nativeType) {
        throw 'Yerel surec envanteri yuklenemedi.'
    }
    foreach ($entry in $nativeType::GetInventory()) {
        [pscustomobject]@{
            ProcessId = [int]$entry[0]
            ParentProcessId = [int]$entry[1]
        }
    }
}
function Get-ExternalProcessTreeIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$RootProcessId,
        [scriptblock]$InventoryProvider
    )
    if ($RootProcessId -eq $PID) {
        throw 'Gecerli PowerShell sureci sonlandirilemez.'
    }
    $inventory = if ($null -ne $InventoryProvider) {
        @(& $InventoryProvider)
    }
    else {
        @(Get-ExternalNativeProcessInventory)
    }
    $children = @{}
    foreach ($entry in $inventory) {
        $processId = [int]$entry.ProcessId
        $parentId = [int]$entry.ParentProcessId
        if ($processId -le 0 -or $parentId -le 0) {
            continue
        }
        if (-not $children.ContainsKey($parentId)) {
            $children[$parentId] = `
                [Collections.Generic.List[int]]::new()
        }
        $children[$parentId].Add($processId)
    }
    $ids = [Collections.Generic.HashSet[int]]::new()
    $pending = [Collections.Generic.Queue[int]]::new()
    $null = $ids.Add($RootProcessId)
    $pending.Enqueue($RootProcessId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        if (-not $children.ContainsKey($parentId)) {
            continue
        }
        foreach ($childId in $children[$parentId]) {
            if ($ids.Add($childId)) {
                $pending.Enqueue($childId)
            }
        }
    }
    return [int[]]@($ids)
}
function Get-ExternalAliveProcessIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$ProcessIds,
        [scriptblock]$StateProvider
    )
    $alive = [Collections.Generic.List[int]]::new()
    foreach ($processId in @($ProcessIds | Select-Object -Unique)) {
        $isAlive = if ($null -ne $StateProvider) {
            [bool](& $StateProvider $processId)
        }
        else {
            $candidate = $null
            try {
                $candidate = [Diagnostics.Process]::GetProcessById(
                    $processId
                )
                -not $candidate.HasExited
            }
            catch [ArgumentException] {
                $false
            }
            catch {
                $true
            }
            finally {
                if ($null -ne $candidate) {
                    $candidate.Dispose()
                }
            }
        }
        if ($isAlive) {
            $alive.Add($processId)
        }
    }
    return [int[]]$alive.ToArray()
}
function Wait-ExternalProcessTreeExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$ProcessIds,
        [ValidateRange(10, 60000)]
        [int]$TimeoutMilliseconds,
        [scriptblock]$StateProvider
    )
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(
        $TimeoutMilliseconds
    )
    do {
        $alive = @(Get-ExternalAliveProcessIds `
            -ProcessIds $ProcessIds -StateProvider $StateProvider)
        if ($alive.Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return @(Get-ExternalAliveProcessIds `
        -ProcessIds $ProcessIds `
        -StateProvider $StateProvider).Count -eq 0
}
function Invoke-ExternalProcessKillTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Process)
    $treeKill = $Process.GetType().GetMethod(
        'Kill',
        [Reflection.BindingFlags]::Instance -bor
            [Reflection.BindingFlags]::Public,
        $null,
        [type[]]@([bool]),
        $null
    )
    if ($null -eq $treeKill) {
        return $false
    }
    $null = $treeKill.Invoke(
        $Process,
        [object[]]@($true)
    )
    return $true
}
function Resolve-TrustedSystemTaskkillPath {
    [CmdletBinding()]
    param()
    $system32 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::System
    )
    if ([string]::IsNullOrWhiteSpace($system32)) {
        throw 'Windows System32 dizini bulunamadi.'
    }
    $system32 = [IO.Path]::GetFullPath($system32).TrimEnd('\')
    $systemItem = Get-Item -LiteralPath $system32 -Force `
        -ErrorAction Stop
    $taskkillPath = Join-Path $system32 'taskkill.exe'
    $taskkillItem = Get-Item -LiteralPath $taskkillPath -Force `
        -ErrorAction Stop
    if ($systemItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint -or
        $taskkillItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint -or
        [IO.Path]::GetFullPath(
            $taskkillItem.DirectoryName
        ).TrimEnd('\') -ine $system32 -or
        [IO.Path]::GetFullPath($taskkillItem.FullName) -ine
            $taskkillPath) {
        throw 'Guvenilir taskkill.exe bulunamadi.'
    }
    $signature = Get-AuthenticodeSignature `
        -LiteralPath $taskkillPath -ErrorAction Stop
    if ($signature.Status -ne
            [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch
            'Microsoft (Corporation|Windows)') {
        throw 'taskkill.exe imzasi dogrulanamadi.'
    }
    return $taskkillPath
}
function Assert-ExternalTaskkillOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Completed,
        [int]$ExitCode,
        [string]$ErrorText = ''
    )
    if (-not $Completed) {
        throw [TimeoutException]::new(
            'taskkill.exe zaman asimina ugradi.'
        )
    }
    if ($ExitCode -ne 0) {
        $message = 'taskkill.exe surec agacini durduramadi. ' +
            "Cikis kodu: $ExitCode"
        if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
            $message += " | $ErrorText"
        }
        throw [InvalidOperationException]::new($message)
    }
}
function Invoke-ExternalTaskkill {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateCount(1, 512)]
        [int[]]$TargetProcessIds,
        [ValidateRange(10, 60000)]
        [int]$TimeoutMilliseconds
    )
    $targetIds = @($TargetProcessIds | Select-Object -Unique)
    if (@($targetIds | Where-Object { $_ -le 0 -or $_ -eq $PID }).Count `
        -gt 0) {
        throw 'Gecersiz taskkill.exe surec kimligi.'
    }
    $taskkillPath = Resolve-TrustedSystemTaskkillPath
    $system32 = [IO.Path]::GetDirectoryName($taskkillPath)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($targetId in $targetIds) {
        $arguments.Add('/PID')
        $arguments.Add([string]$targetId)
    }
    $arguments.Add('/T')
    $arguments.Add('/F')
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $taskkillPath
    $info.Arguments = $arguments.ToArray() -join ' '
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
        $completed = $killer.WaitForExit($TimeoutMilliseconds)
        if (-not $completed) {
            try {
                $killer.Kill()
                $null = $killer.WaitForExit(2000)
            }
            catch {
            }
        }
        $outputComplete = Wait-ExternalProcessOutputTasks `
            -Tasks ([Threading.Tasks.Task[]]@(
                $stdoutTask,
                $stderrTask
            )) -TimeoutMilliseconds 2000
        $errorText = if ($outputComplete) {
            $stderrTask.GetAwaiter().GetResult().Trim()
        }
        else {
            try {
                $killer.StandardOutput.Dispose()
            }
            catch {
            }
            try {
                $killer.StandardError.Dispose()
            }
            catch {
            }
            ''
        }
        Assert-ExternalTaskkillOutcome -Completed $completed `
            -ExitCode $(if ($completed) {
                [int]$killer.ExitCode
            }
            else {
                0
            }) -ErrorText $errorText
    }
    finally {
        $killer.Dispose()
    }
}
function Stop-ExternalProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Process,
        [ValidateRange(10, 60000)]
        [int]$WaitMilliseconds = 5000,
        [scriptblock]$SnapshotProvider,
        [scriptblock]$StateProvider,
        [scriptblock]$KillTreeInvoker,
        [scriptblock]$TaskkillInvoker
    )
    $rootProcessId = [int]$Process.Id
    if ($rootProcessId -le 0 -or $rootProcessId -eq $PID) {
        throw 'Gecersiz alt surec kimligi.'
    }
    try {
        if ([bool]$Process.HasExited) {
            return
        }
    }
    catch {
    }
    [int[]]$treeIds = @(
        if ($null -ne $SnapshotProvider) {
            & $SnapshotProvider $rootProcessId
        }
        else {
            Get-ExternalProcessTreeIds `
                -RootProcessId $rootProcessId
        }
    )
    if ($treeIds.Count -eq 0 -or
        $rootProcessId -notin $treeIds) {
        throw 'Alt surec agaci kimligi dogrulanamadi.'
    }
    $alive = @(Get-ExternalAliveProcessIds `
        -ProcessIds $treeIds -StateProvider $StateProvider)
    if ($alive.Count -eq 0) {
        return
    }
    $treeKillInvoked = $false
    try {
        $treeKillInvoked = if ($null -ne $KillTreeInvoker) {
            [bool](& $KillTreeInvoker $Process)
        }
        else {
            Invoke-ExternalProcessKillTree -Process $Process
        }
    }
    catch {
        Write-Verbose ('Kill(true) surec agaci durduramadi: {0}' -f `
            $_.Exception.Message)
    }
    if ($treeKillInvoked -and
        (Wait-ExternalProcessTreeExit -ProcessIds $treeIds `
            -TimeoutMilliseconds $WaitMilliseconds `
            -StateProvider $StateProvider)) {
        return
    }
    $terminationErrors = [Collections.Generic.List[Exception]]::new()
    $alive = @(Get-ExternalAliveProcessIds `
        -ProcessIds $treeIds -StateProvider $StateProvider)
    [int[]]$targets = @(
        if ($rootProcessId -in $alive) {
            $rootProcessId
        }
        else {
            $alive
        }
    )
    if ($targets.Count -gt 0) {
        try {
            if ($null -ne $TaskkillInvoker) {
                & $TaskkillInvoker $targets $WaitMilliseconds
            }
            else {
                Invoke-ExternalTaskkill `
                    -TargetProcessIds $targets `
                    -TimeoutMilliseconds $WaitMilliseconds
            }
        }
        catch {
            $terminationErrors.Add($_.Exception)
        }
    }
    $null = Wait-ExternalProcessTreeExit -ProcessIds $treeIds `
        -TimeoutMilliseconds $WaitMilliseconds `
        -StateProvider $StateProvider
    $alive = @(Get-ExternalAliveProcessIds `
        -ProcessIds $treeIds -StateProvider $StateProvider)
    if ($alive.Count -gt 0 -and
        $rootProcessId -notin $alive) {
        try {
            if ($null -ne $TaskkillInvoker) {
                & $TaskkillInvoker ([int[]]$alive) $WaitMilliseconds
            }
            else {
                Invoke-ExternalTaskkill `
                    -TargetProcessIds ([int[]]$alive) `
                    -TimeoutMilliseconds $WaitMilliseconds
            }
        }
        catch {
            $terminationErrors.Add($_.Exception)
        }
        $null = Wait-ExternalProcessTreeExit `
            -ProcessIds $treeIds `
            -TimeoutMilliseconds $WaitMilliseconds `
            -StateProvider $StateProvider
        $alive = @(Get-ExternalAliveProcessIds `
            -ProcessIds $treeIds -StateProvider $StateProvider)
    }
    if ($alive.Count -gt 0) {
        $terminationErrors.Add([InvalidOperationException]::new(
            'Alt surec agaci durdurulamadi: ' +
            ($alive -join ', ')
        ))
    }
    if ($terminationErrors.Count -gt 0) {
        throw [AggregateException]::new(
            'Alt surec agaci sonlandirma hatasi.',
            [Exception[]]$terminationErrors.ToArray()
        )
    }
}
function New-ExternalProcessTimeoutException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Exception]$TerminationError
    )
    $error = [TimeoutException]::new(
        (Get-LocalizedText `
            -Key 'Common.Error.ProcessTimeout' `
            -Arguments @($FilePath))
    )
    if ($null -ne $TerminationError) {
        $error.Data['TerminationError'] = $TerminationError.Message
    }
    return $error
}
function Invoke-ExternalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 900,
        [int[]]$AllowedExitCodes = @(0),
        [string]$WorkingDirectory,
        [string]$Activity
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $resolved = Resolve-ExecutablePath -Name $FilePath
        if ($null -eq $resolved) {
            throw (Get-LocalizedText `
                -Key 'Process.Error.ExecutableMissing' `
                -Arguments @($FilePath))
        }
        $FilePath = $resolved
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if ([string]::IsNullOrWhiteSpace($Activity)) {
        $Activity = Get-ExternalProcessActivity `
            -FilePath $FilePath -ArgumentList $ArgumentList
    }
    $startedAt = [DateTimeOffset]::UtcNow
    $lastHeartbeat = $startedAt
    try {
        Write-DeploymentStatusLine `
            -Status (Get-LocalizedText `
                -Key 'Common.Level.Running') `
            -Module (Get-LocalizedText -Key 'Module.Process') `
            -Message (Get-LocalizedText -Key 'Process.Started' `
                -Arguments @($Activity)) `
            -StatusCode RUNNING -ModuleCode PROCESS
        if (-not $process.Start()) {
            throw (Get-LocalizedText -Key 'Process.Error.StartFailed' `
                -Arguments @($FilePath))
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = $startedAt.AddSeconds($TimeoutSeconds)
        $timedOut = $false
        $terminationError = $null
        while (-not $process.WaitForExit(1000)) {
            $now = [DateTimeOffset]::UtcNow
            if ($now -ge $deadline) {
                $timedOut = $true
                try {
                    Stop-ExternalProcessTree -Process $process
                }
                catch {
                    $terminationError = $_.Exception
                    Write-Verbose (
                        'Alt surec agaci temizligi basarisiz: {0}' -f `
                            $terminationError.Message
                    )
                }
                break
            }
            if (($now - $lastHeartbeat).TotalSeconds -ge 15) {
                $elapsed = [math]::Round(
                    ($now - $startedAt).TotalSeconds
                )
                Write-DeploymentStatusLine `
                    -Status (Get-LocalizedText `
                        -Key 'Common.Level.Waiting') `
                    -Module (Get-LocalizedText `
                        -Key 'Module.Process') `
                    -Message (Get-LocalizedText `
                        -Key 'Process.Waiting' `
                        -Arguments @($Activity, $elapsed)) `
                    -StatusCode WAITING -ModuleCode PROCESS
                $lastHeartbeat = $now
            }
        }
        $outputTasks = [Threading.Tasks.Task[]]@(
            $stdoutTask,
            $stderrTask
        )
        $outputComplete = Wait-ExternalProcessOutputTasks `
            -Tasks $outputTasks -TimeoutMilliseconds 5000
        if (-not $outputComplete) {
            try {
                $process.StandardOutput.Dispose()
            }
            catch {
            }
            try {
                $process.StandardError.Dispose()
            }
            catch {
            }
            Write-Verbose (
                'Alt surec cikti kanallari sinirli surede kapanmadi: {0}' `
                    -f $FilePath
            )
        }
        $stdout = if ($outputComplete) {
            $stdoutTask.GetAwaiter().GetResult()
        }
        else {
            ''
        }
        $stderr = if ($outputComplete) {
            $stderrTask.GetAwaiter().GetResult()
        }
        else {
            ''
        }
        if ($timedOut) {
            throw (New-ExternalProcessTimeoutException `
                -FilePath $FilePath `
                -TerminationError $terminationError)
        }
        $result = [pscustomobject]@{
            FilePath = $FilePath
            ExitCode = $process.ExitCode
            OutputComplete = $outputComplete
            StandardOutput = $stdout.TrimEnd()
            StandardError = $stderr.TrimEnd()
            Duration = [DateTimeOffset]::UtcNow - $startedAt
        }
        if ($result.ExitCode -notin $AllowedExitCodes) {
            $details = @(
                $result.StandardError
                $result.StandardOutput
            ) | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
            $message = Get-LocalizedText `
                -Key 'Process.Error.Failed' `
                -Arguments @(
                    $FilePath,
                    $Activity,
                    $result.ExitCode,
                    ($details -join [Environment]::NewLine)
                )
            throw $message
        }
        Write-DeploymentStatusLine `
            -Status (Get-LocalizedText -Key 'Common.Level.Ok') `
            -Module (Get-LocalizedText -Key 'Module.Process') `
            -Message (Get-LocalizedText -Key 'Process.Completed' `
                -Arguments @($Activity, $result.Duration)) `
            -StatusCode OK -ModuleCode PROCESS
        return $result
    }
    finally {
        try {
            $process.Dispose()
        }
        catch {
            Write-Verbose ('Alt surec nesnesi kapatilamadi: {0}' -f `
                $_.Exception.Message)
        }
    }
}
function Assert-ExternalProcessContracts {
    [CmdletBinding()]
    param()
    $completed = [Threading.Tasks.Task]::FromResult('hazir')
    if (-not (Wait-ExternalProcessOutputTasks `
        -Tasks ([Threading.Tasks.Task[]]@($completed)) `
        -TimeoutMilliseconds 100)) {
        throw 'Tamamlanan cikti gorevi kabul edilmedi.'
    }
    $pending = [Threading.Tasks.TaskCompletionSource[string]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $unexpectedCompletion = Wait-ExternalProcessOutputTasks `
        -Tasks ([Threading.Tasks.Task[]]@($pending.Task)) `
        -TimeoutMilliseconds 25
    $watch.Stop()
    $null = $pending.TrySetCanceled()
    $invokeSource = (Get-Command Invoke-ExternalProcess `
        -ErrorAction Stop).Definition
    $stopSource = (Get-Command Stop-ExternalProcessTree `
        -ErrorAction Stop).Definition
    $taskkillSource = (Get-Command Invoke-ExternalTaskkill `
        -ErrorAction Stop).Definition
    $taskkillPathSource = (Get-Command `
        Resolve-TrustedSystemTaskkillPath `
        -ErrorAction Stop).Definition
    if ($unexpectedCompletion -or $watch.ElapsedMilliseconds -gt 1000 -or
        $invokeSource -notmatch 'Wait-ExternalProcessOutputTasks' -or
        $invokeSource -notmatch 'TimeoutMilliseconds 5000' -or
        $invokeSource -notmatch
            'OutputComplete = \$outputComplete' -or
        $invokeSource -notmatch
            'ExitCode -notin \$AllowedExitCodes' -or
        $invokeSource -match 'WaitForExit\(\s*\)' -or
        $invokeSource -notmatch 'Stop-ExternalProcessTree' -or
        $stopSource -notmatch 'Invoke-ExternalProcessKillTree' -or
        $stopSource -notmatch 'Invoke-ExternalTaskkill' -or
        $stopSource -notmatch 'Wait-ExternalProcessTreeExit' -or
        $taskkillSource -notmatch "'/PID'" -or
        $taskkillSource -notmatch "'/T'" -or
        $taskkillSource -notmatch "'/F'" -or
        $taskkillSource -notmatch
            'WaitForExit\(\$TimeoutMilliseconds\)' -or
        $taskkillPathSource -notmatch
            'Environment\+SpecialFolder]::System' -or
        $taskkillPathSource -notmatch
            'Get-AuthenticodeSignature' -or
        $taskkillPathSource -notmatch
            'SignatureStatus]::Valid') {
        throw 'Alt surec cikti bekleme siniri gecersiz.'
    }
    $killAlive = [Collections.Generic.HashSet[int]]::new()
    $null = $killAlive.Add(700001)
    $null = $killAlive.Add(700002)
    $killState = {
        param($TargetProcessId)
        return $killAlive.Contains([int]$TargetProcessId)
    }.GetNewClosure()
    $killSnapshot = {
        param($RootProcessId)
        return [int[]]@($RootProcessId, 700002)
    }
    $killInvoker = {
        param($TargetProcess)
        $killAlive.Clear()
        return $true
    }.GetNewClosure()
    $unexpectedTaskkill = {
        param($TargetProcessIds, $TimeoutMilliseconds)
        throw 'Kill(true) sonrasi taskkill cagrildi.'
    }
    $fakeProcess = [pscustomobject]@{
        Id = 700001
        HasExited = $false
    }
    Stop-ExternalProcessTree -Process $fakeProcess `
        -WaitMilliseconds 20 `
        -SnapshotProvider $killSnapshot `
        -StateProvider $killState `
        -KillTreeInvoker $killInvoker `
        -TaskkillInvoker $unexpectedTaskkill
    $taskkillTimeoutRejected = $false
    $timeoutAlive = [Collections.Generic.HashSet[int]]::new()
    $null = $timeoutAlive.Add(700011)
    $timeoutState = {
        param($TargetProcessId)
        return $timeoutAlive.Contains([int]$TargetProcessId)
    }.GetNewClosure()
    $timeoutSnapshot = {
        param($RootProcessId)
        return [int[]]@($RootProcessId)
    }
    $unsupportedKill = {
        param($TargetProcess)
        return $false
    }
    $timedOutTaskkill = {
        param($TargetProcessIds, $TimeoutMilliseconds)
        Assert-ExternalTaskkillOutcome `
            -Completed:$false -ExitCode 0
    }
    try {
        Stop-ExternalProcessTree `
            -Process ([pscustomobject]@{
                Id = 700011
                HasExited = $false
            }) -WaitMilliseconds 20 `
            -SnapshotProvider $timeoutSnapshot `
            -StateProvider $timeoutState `
            -KillTreeInvoker $unsupportedKill `
            -TaskkillInvoker $timedOutTaskkill
    }
    catch {
        $taskkillTimeoutRejected =
            $_.Exception.ToString() -match
                'taskkill\.exe zaman asimina ugradi'
    }
    $taskkillNonzeroRejected = $false
    $nonzeroAlive = [Collections.Generic.HashSet[int]]::new()
    $null = $nonzeroAlive.Add(700021)
    $nonzeroState = {
        param($TargetProcessId)
        return $nonzeroAlive.Contains([int]$TargetProcessId)
    }.GetNewClosure()
    $nonzeroTaskkill = {
        param($TargetProcessIds, $TimeoutMilliseconds)
        Assert-ExternalTaskkillOutcome `
            -Completed:$true -ExitCode 5
    }
    try {
        Stop-ExternalProcessTree `
            -Process ([pscustomobject]@{
                Id = 700021
                HasExited = $false
            }) -WaitMilliseconds 20 `
            -SnapshotProvider $timeoutSnapshot `
            -StateProvider $nonzeroState `
            -KillTreeInvoker $unsupportedKill `
            -TaskkillInvoker $nonzeroTaskkill
    }
    catch {
        $taskkillNonzeroRejected =
            $_.Exception.ToString() -match 'Cikis kodu: 5'
    }
    $survivorRejected = $false
    $survivors = [Collections.Generic.HashSet[int]]::new()
    $null = $survivors.Add(700031)
    $null = $survivors.Add(700032)
    $survivorState = {
        param($TargetProcessId)
        return $survivors.Contains([int]$TargetProcessId)
    }.GetNewClosure()
    $survivorSnapshot = {
        param($RootProcessId)
        return [int[]]@($RootProcessId, 700032)
    }
    $ineffectiveTaskkill = {
        param($TargetProcessIds, $TimeoutMilliseconds)
    }
    try {
        Stop-ExternalProcessTree `
            -Process ([pscustomobject]@{
                Id = 700031
                HasExited = $false
            }) -WaitMilliseconds 20 `
            -SnapshotProvider $survivorSnapshot `
            -StateProvider $survivorState `
            -KillTreeInvoker $unsupportedKill `
            -TaskkillInvoker $ineffectiveTaskkill
    }
    catch {
        $survivorRejected =
            $_.Exception.ToString() -match '700031, 700032'
    }
    $terminationFailure = [InvalidOperationException]::new(
        'fixture termination failure'
    )
    $timeoutError = New-ExternalProcessTimeoutException `
        -FilePath 'fixture.exe' `
        -TerminationError $terminationFailure
    $primaryPreserved =
        $timeoutError -is [TimeoutException] -and
        [string]$timeoutError.Data['TerminationError'] -eq
            $terminationFailure.Message
    if (-not $taskkillTimeoutRejected -or
        -not $taskkillNonzeroRejected -or
        -not $survivorRejected -or
        -not $primaryPreserved) {
        throw 'Alt surec agaci sonlandirma sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.OutputDrainBounded'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.ExitCodePropagation'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.KillTreeBounded'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.TaskkillFallback'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.TreeExitFailClosed'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Process.TimeoutPrimaryPreserved'
    return $true
}
function Get-VersionFromText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    $match = [regex]::Match($Text, '\d+\.\d+(?:\.\d+){0,2}')
    if (-not $match.Success) {
        return $null
    }
    return [version]$match.Value
}
Export-ModuleMember -Function @(
    'Resolve-ExecutablePath', 'Get-ExternalProcessActivity',
    'Invoke-ExternalProcess', 'Assert-ExternalProcessContracts',
    'Get-VersionFromText'
)