param([switch]$MutateBypassStartGate)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$lifecyclePath = Join-Path $root "transcript-job-lifecycle.ps1"

if (-not (Test-Path -LiteralPath $lifecyclePath)) {
    throw "GUI job lifecycle helper is missing: $lifecyclePath"
}

. $lifecyclePath

if (-not ("LifecycleTestProcessHandle" -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class LifecycleTestProcessHandle : IDisposable
{
    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint WAIT_OBJECT_0 = 0x00000000;

    private IntPtr handle;

    private LifecycleTestProcessHandle(IntPtr handle)
    {
        this.handle = handle;
    }

    public static LifecycleTestProcessHandle Open(int processId, long creationFileTimeUtc)
    {
        IntPtr processHandle = OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            false,
            processId);
        if (processHandle == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open lifecycle fixture process.");
        }

        try
        {
            FILETIME creation;
            FILETIME exit;
            FILETIME kernel;
            FILETIME user;
            if (!GetProcessTimes(processHandle, out creation, out exit, out kernel, out user))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not validate lifecycle fixture process.");
            }

            long actualCreationFileTimeUtc = ((long)creation.dwHighDateTime << 32) | creation.dwLowDateTime;
            if (actualCreationFileTimeUtc != creationFileTimeUtc)
            {
                throw new InvalidOperationException("Lifecycle fixture process identity changed before its handle was captured.");
            }

            LifecycleTestProcessHandle result = new LifecycleTestProcessHandle(processHandle);
            processHandle = IntPtr.Zero;
            return result;
        }
        finally
        {
            if (processHandle != IntPtr.Zero)
            {
                CloseHandle(processHandle);
            }
        }
    }

    public bool HasExited
    {
        get
        {
            EnsureOpen();
            return WaitForSingleObject(handle, 0) == WAIT_OBJECT_0;
        }
    }

    public void Terminate()
    {
        EnsureOpen();
        if (HasExited)
        {
            return;
        }

        if (!TerminateProcess(handle, 1))
        {
            int error = Marshal.GetLastWin32Error();
            if (!HasExited)
            {
                throw new Win32Exception(error, "Could not terminate lifecycle fixture process.");
            }
        }
    }

    public bool WaitForExit(int milliseconds)
    {
        EnsureOpen();
        return WaitForSingleObject(handle, (uint)milliseconds) == WAIT_OBJECT_0;
    }

    public void Dispose()
    {
        IntPtr current = handle;
        handle = IntPtr.Zero;
        if (current != IntPtr.Zero)
        {
            CloseHandle(current);
        }
    }

    private void EnsureOpen()
    {
        if (handle == IntPtr.Zero)
        {
            throw new ObjectDisposedException("LifecycleTestProcessHandle");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(
        IntPtr process,
        out FILETIME creation,
        out FILETIME exit,
        out FILETIME kernel,
        out FILETIME user);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-StartGate {
    param([Parameter(Mandatory = $true)][string]$Name)

    New-Object System.Threading.EventWaitHandle -ArgumentList @(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $Name
    )
}

function Start-HiddenLifecycleNativeProcess {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw "Could not start hidden lifecycle native fixture."
    }

    return $process
}

function Start-LifecycleFixtureJob {
    param(
        [Parameter(Mandatory = $true)][string]$NativeExe,
        [Parameter(Mandatory = $true)][string]$WorkerIdentityPath,
        [Parameter(Mandatory = $true)][string]$StartGateName,
        [Parameter(Mandatory = $true)][string]$PostGateMarkerPath,
        [switch]$BypassStartGate
    )

    Start-Job `
        -ArgumentList @(
            $NativeExe,
            $WorkerIdentityPath,
            $StartGateName,
            $PostGateMarkerPath,
            [bool]$BypassStartGate
        ) `
        -ScriptBlock {
        param(
            $nativeExe,
            $workerIdentityPath,
            $startGateName,
            $postGateMarkerPath,
            $bypassStartGate
        )

        $ErrorActionPreference = "Stop"
        $workerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        $workerIdentity = [pscustomobject]@{
            Id = $PID
            CreationFileTimeUtc = $workerProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        }
        [System.IO.File]::WriteAllText(
            $workerIdentityPath,
            ($workerIdentity | ConvertTo-Json -Compress)
        )
        $startGate = [System.Threading.EventWaitHandle]::OpenExisting($startGateName)

        try {
            [pscustomobject]@{
                Kind = "Worker"
                Value = $workerIdentity
            }

            if (-not $bypassStartGate) {
                [void]$startGate.WaitOne()
            }
        }
        finally {
            $startGate.Dispose()
        }

        [System.IO.File]::WriteAllText($postGateMarkerPath, "started")
        $nativeStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $nativeStartInfo.FileName = $nativeExe
        $nativeStartInfo.UseShellExecute = $false
        $nativeStartInfo.CreateNoWindow = $true
        $nativeStartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $nativeProcess = New-Object System.Diagnostics.Process
        $nativeProcess.StartInfo = $nativeStartInfo
        try {
            if (-not $nativeProcess.Start()) {
                throw "Could not start hidden lifecycle native fixture."
            }
            $nativeIdentity = [pscustomobject]@{
                Id = $nativeProcess.Id
                CreationFileTimeUtc = $nativeProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
                CreateNoWindow = $nativeStartInfo.CreateNoWindow
                UseShellExecute = $nativeStartInfo.UseShellExecute
            }
            [pscustomobject]@{
                Kind = "Native"
                Value = $nativeIdentity
            }
            $nativeProcess.WaitForExit()
        }
        finally {
            $nativeProcess.Dispose()
        }
    }
}

function Start-CrashSafeSaveFixtureJob {
    param(
        [string]$ModulePath,
        [string]$NativeExe,
        [string]$SourcePath,
        [string]$OutputDir,
        [string]$OperationId,
        [string]$WorkerIdentityPath,
        [string]$StartGateName
    )

    Start-Job -ArgumentList @(
        $ModulePath, $NativeExe, $SourcePath, $OutputDir, $OperationId,
        $WorkerIdentityPath, $StartGateName
    ) -ScriptBlock {
        param($modulePath, $nativeExe, $sourcePath, $outputDir, $operationId,
            $workerIdentityPath, $startGateName)
        $ErrorActionPreference = "Stop"
        $worker = [System.Diagnostics.Process]::GetCurrentProcess()
        $identity = [pscustomobject]@{
            Id = $PID
            CreationFileTimeUtc = $worker.StartTime.ToUniversalTime().ToFileTimeUtc()
        }
        [System.IO.File]::WriteAllText($workerIdentityPath, ($identity | ConvertTo-Json -Compress))
        $gate = [System.Threading.EventWaitHandle]::OpenExisting($startGateName)
        try {
            [pscustomobject]@{ Kind = "Worker"; Value = $identity }
            [void]$gate.WaitOne()
        }
        finally { $gate.Dispose() }

        Import-Module $modulePath -Force
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + $operationId)
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $nativeExe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $native = New-Object System.Diagnostics.Process
        $native.StartInfo = $psi
        if (-not $native.Start()) { throw "Could not start hidden cancellation fixture." }
        [pscustomobject]@{
            Kind = "Native"
            Value = [pscustomobject]@{
                Id = $native.Id
                CreationFileTimeUtc = $native.StartTime.ToUniversalTime().ToFileTimeUtc()
                CreateNoWindow = $psi.CreateNoWindow
                UseShellExecute = $psi.UseShellExecute
            }
        }
        Save-TranscriptFromSubtitleFile `
            -Path $sourcePath `
            -OutputDir $outputDir `
            -CleanTranscript $true `
            -OperationId $operationId | Out-Null
        $native.WaitForExit()
    }
}

function New-LifecycleTestProcessHandle {
    param([Parameter(Mandatory = $true)][object]$Identity)

    [LifecycleTestProcessHandle]::Open(
        [int]$Identity.Id,
        [long]$Identity.CreationFileTimeUtc
    )
}

function Receive-LifecycleMessages {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Job]$Job,
        [Parameter(Mandatory = $true)][string[]]$RequiredKinds
    )

    $messages = @()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while ([DateTime]::UtcNow -lt $deadline) {
        $messages += @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)
        $receivedKinds = @($messages | ForEach-Object { [string]$_.Kind })
        $missingKinds = @($RequiredKinds | Where-Object { $receivedKinds -notcontains $_ })

        if ($missingKinds.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 25
    }

    return $messages
}

function Stop-LifecycleFixture {
    param(
        [System.Management.Automation.Job]$Job,
        [object]$ProcessGroup,
        [object]$WorkerHandle,
        [object]$NativeHandle,
        [object]$WorkerIdentity,
        [object]$NativeIdentity
    )

    $workerHandleToDispose = $WorkerHandle
    $nativeHandleToDispose = $NativeHandle

    try {
        if ($Job) {
            if (-not $WorkerIdentity) {
                $workerMessage = $Job.ChildJobs[0].Output |
                    Where-Object Kind -eq "Worker" |
                    Select-Object -First 1
                if ($workerMessage) {
                    $WorkerIdentity = $workerMessage.Value
                }
            }

            if (-not $NativeIdentity) {
                $nativeMessage = $Job.ChildJobs[0].Output |
                    Where-Object Kind -eq "Native" |
                    Select-Object -First 1
                if ($nativeMessage) {
                    $NativeIdentity = $nativeMessage.Value
                }
            }
        }

        if (-not $workerHandleToDispose -and $WorkerIdentity) {
            try {
                $workerHandleToDispose = New-LifecycleTestProcessHandle -Identity $WorkerIdentity
            }
            catch {}
        }

        if (-not $nativeHandleToDispose -and $NativeIdentity) {
            try {
                $nativeHandleToDispose = New-LifecycleTestProcessHandle -Identity $NativeIdentity
            }
            catch {}
        }

        if ($ProcessGroup) {
            try { $ProcessGroup.Terminate() } catch {}
        }

        if ($nativeHandleToDispose) {
            try { $nativeHandleToDispose.Terminate() } catch {}
        }

        if ($workerHandleToDispose) {
            try { $workerHandleToDispose.Terminate() } catch {}
        }

        if ($nativeHandleToDispose) {
            try { [void]$nativeHandleToDispose.WaitForExit(3000) } catch {}
        }

        if ($workerHandleToDispose) {
            try { [void]$workerHandleToDispose.WaitForExit(3000) } catch {}
        }

        if ($Job) {
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while ([DateTime]::UtcNow -lt $deadline -and
                $Job.State -notin "Completed", "Failed", "Stopped") {
                Start-Sleep -Milliseconds 25
            }
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        if ($ProcessGroup) {
            try { $ProcessGroup.Dispose() } catch {}
        }
        if ($nativeHandleToDispose) {
            try { $nativeHandleToDispose.Dispose() } catch {}
        }
        if ($workerHandleToDispose) {
            try { $workerHandleToDispose.Dispose() } catch {}
        }
    }
}

function Assert-ProcessHandleExited {
    param(
        [Parameter(Mandatory = $true)][object]$ProcessHandle,
        [string]$Description
    )

    Assert-True `
        $ProcessHandle.WaitForExit(3000) `
        "$Description process survived cleanup."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-job-lifecycle-" + [Guid]::NewGuid().ToString("N"))
$nativeExe = Join-Path $tempRoot "slow-native.exe"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$source = @'
using System;
using System.Threading;

public class Program
{
    public static int Main(string[] args)
    {
        Thread.Sleep(30000);
        return 0;
    }
}
'@

Add-Type -TypeDefinition $source -OutputAssembly $nativeExe -OutputType ConsoleApplication

$tests = @(
    @{
        Name = "Active native child uses bounded UI stop and deferred cleanup"
        Run = {
            $job = $null
            $processGroup = $null
            $workerIdentity = $null
            $nativeIdentity = $null
            $workerHandle = $null
            $nativeHandle = $null
            $identityPath = Join-Path $tempRoot ("active-" + [Guid]::NewGuid().ToString("N") + ".json")
            $postGateMarkerPath = Join-Path $tempRoot ("active-post-gate-" + [Guid]::NewGuid().ToString("N"))
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName `
                    -PostGateMarkerPath $postGateMarkerPath
                $workerMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker"))
                $workerIdentity = ($workerMessages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity
                $processGroup = New-TranscriptProcessGroup -WorkerIdentity $workerIdentity
                [void]$startGate.Set()
                $startGate.Dispose()
                $startGate = $null

                $nativeMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native"))
                $nativeIdentity = ($nativeMessages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value
                Assert-True ([bool]$nativeIdentity.CreateNoWindow) "Lifecycle native fixture was not launched with CreateNoWindow."
                Assert-True (-not [bool]$nativeIdentity.UseShellExecute) "Lifecycle native fixture unexpectedly used the shell."
                $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeIdentity
                Assert-True ($job.State -eq "Running") "Expected active fixture job."

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -ProcessGroup $processGroup `
                    -WorkerIdentity $workerIdentity `
                    -WorkerIdentityPath $identityPath `
                    -UiDeadlineMilliseconds 1500
                $stopwatch.Stop()

                Assert-True ($stopwatch.ElapsedMilliseconds -le 2000) "UI stop took $($stopwatch.ElapsedMilliseconds) ms."
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Worker"
                Assert-ProcessHandleExited -ProcessHandle $nativeHandle -Description "Native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Deferred cleanup did not remove the job."

                $job = $null
                $processGroup = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - active native child"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture `
                    -Job $job `
                    -ProcessGroup $processGroup `
                    -WorkerHandle $workerHandle `
                    -NativeHandle $nativeHandle `
                    -WorkerIdentity $workerIdentity `
                    -NativeIdentity $nativeIdentity
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $postGateMarkerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "UI stop request never calls a slow process-group terminator"
        Run = {
            $job = $null
            $realProcessGroup = $null
            $slowGroup = $null
            $workerIdentity = $null
            $nativeIdentity = $null
            $workerHandle = $null
            $nativeHandle = $null
            $identityPath = Join-Path $tempRoot ("slow-terminate-" + [Guid]::NewGuid().ToString("N") + ".json")
            $postGateMarkerPath = Join-Path $tempRoot ("slow-terminate-post-gate-" + [Guid]::NewGuid().ToString("N"))
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName `
                    -PostGateMarkerPath $postGateMarkerPath
                $workerMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker"))
                $workerIdentity = ($workerMessages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity
                $realProcessGroup = New-TranscriptProcessGroup -WorkerIdentity $workerIdentity
                $slowGroup = [pscustomobject]@{
                    Inner = $realProcessGroup
                    TerminateCalls = 0
                    DisposeCalls = 0
                }
                $slowGroup | Add-Member ScriptMethod Terminate {
                    $this.TerminateCalls++
                    Start-Sleep -Milliseconds 2300
                    $this.Inner.Terminate()
                }
                $slowGroup | Add-Member ScriptMethod Dispose {
                    $this.DisposeCalls++
                    $this.Inner.Dispose()
                }
                [void]$startGate.Set()
                $startGate.Dispose()
                $startGate = $null
                $nativeMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native"))
                $nativeIdentity = ($nativeMessages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value
                $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeIdentity

                $requestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -ProcessGroup $slowGroup `
                    -WorkerIdentity $workerIdentity `
                    -WorkerIdentityPath $identityPath `
                    -UiDeadlineMilliseconds 100
                $requestStopwatch.Stop()

                Assert-True ($requestStopwatch.ElapsedMilliseconds -lt 200) "UI request blocked for $($requestStopwatch.ElapsedMilliseconds) ms on slow Terminate()."
                Assert-True ($slowGroup.TerminateCalls -eq 0) "UI request synchronously called Terminate()."

                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-True ($slowGroup.TerminateCalls -eq 1) "Deferred cleanup did not own the single Terminate() call."
                Assert-True ($slowGroup.DisposeCalls -eq 1) "Deferred cleanup did not dispose the process group."
                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Slow-terminate worker"
                Assert-ProcessHandleExited -ProcessHandle $nativeHandle -Description "Slow-terminate native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Slow-terminate cleanup did not remove the job."

                $job = $null
                $realProcessGroup = $null
                $slowGroup = $null
                Write-Host "PASS $($requestStopwatch.ElapsedMilliseconds) ms - slow termination deferred"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture `
                    -Job $job `
                    -ProcessGroup $slowGroup `
                    -WorkerHandle $workerHandle `
                    -NativeHandle $nativeHandle `
                    -WorkerIdentity $workerIdentity `
                    -NativeIdentity $nativeIdentity
                if ($realProcessGroup -and -not $slowGroup) {
                    try { $realProcessGroup.Dispose() } catch {}
                }
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $postGateMarkerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Cancellation after staging removes operation outputs and workspaces"
        Run = {
            $job = $null
            $processGroup = $null
            $workerHandle = $null
            $nativeHandle = $null
            $operationId = [Guid]::NewGuid().ToString("N")
            $outputDir = Join-Path $tempRoot ("cancel-output-" + $operationId)
            $sourcePath = Join-Path $tempRoot ("cancel-source-" + $operationId + ".vtt")
            $identityPath = Join-Path $tempRoot ("cancel-worker-" + $operationId + ".json")
            $stagingRoot = Join-Path $outputDir (".youtube-transcript-operation-" + $operationId)
            $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + $operationId)
            $gateName = "Local\TranscriptCrashSafe-" + $operationId
            $startGate = New-StartGate -Name $gateName
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append("WEBVTT`r`n`r`n00:00:00.000 --> 01:00:00.000`r`n")
            for ($index = 0; $index -lt 120000; $index++) {
                [void]$builder.Append("Crash-safe caption ").Append($index).Append(".`r`n")
            }
            [System.IO.File]::WriteAllText($sourcePath, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))

            try {
                $job = Start-CrashSafeSaveFixtureJob `
                    -ModulePath (Join-Path $root "transcript-tool.psm1") `
                    -NativeExe $nativeExe `
                    -SourcePath $sourcePath `
                    -OutputDir $outputDir `
                    -OperationId $operationId `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName
                $workerMessage = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker")) |
                    Where-Object Kind -eq "Worker" | Select-Object -First 1
                $workerIdentity = $workerMessage.Value
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity
                $processGroup = New-TranscriptProcessGroup -WorkerIdentity $workerIdentity
                [void]$startGate.Set()
                $startGate.Dispose(); $startGate = $null
                $nativeMessage = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native")) |
                    Where-Object Kind -eq "Native" | Select-Object -First 1
                Assert-True ([bool]$nativeMessage.Value.CreateNoWindow) "Cancellation native fixture was visible."
                $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeMessage.Value

                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $stagingRoot) -and [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 10
                }
                Assert-True (Test-Path -LiteralPath $stagingRoot) "Operation never reached its staging point."
                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job -ProcessGroup $processGroup -WorkerIdentity $workerIdentity `
                    -WorkerIdentityPath $identityPath -OperationId $operationId `
                    -OutputDir $outputDir -TemporaryDirectory $temporaryDirectory `
                    -StagingRoot $stagingRoot -UiDeadlineMilliseconds 100
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket

                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Cancelled staging worker"
                Assert-ProcessHandleExited -ProcessHandle $nativeHandle -Description "Cancelled staging native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Cancelled staging job remained."
                Assert-True (-not (Test-Path -LiteralPath $stagingRoot)) "Operation staging root leaked."
                Assert-True (-not (Test-Path -LiteralPath $temporaryDirectory)) "GUI temporary workspace leaked."
                $outputs = @(Get-ChildItem -LiteralPath $outputDir -File -ErrorAction SilentlyContinue)
                Assert-True ($outputs.Count -eq 0) "Cancellation left final/lock outputs: $($outputs.Name -join ', ')"
                $job = $null; $processGroup = $null
                Write-Host "PASS cancellation staging cleanup"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture -Job $job -ProcessGroup $processGroup `
                    -WorkerHandle $workerHandle -NativeHandle $nativeHandle
                Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Close before first timer tick cannot start native work"
        Run = {
            $job = $null
            $workerIdentity = $null
            $workerHandle = $null
            $nativeIdentity = $null
            $nativeHandle = $null
            $identityPath = Join-Path $tempRoot ("pretick-" + [Guid]::NewGuid().ToString("N") + ".json")
            $postGateMarkerPath = Join-Path $tempRoot ("pretick-post-gate-" + [Guid]::NewGuid().ToString("N"))
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName `
                    -PostGateMarkerPath $postGateMarkerPath `
                    -BypassStartGate:$MutateBypassStartGate
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $identityPath) -and [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (Test-Path -LiteralPath $identityPath) "Worker identity handoff was not written."
                $workerIdentity = Get-TranscriptWorkerIdentity -Path $identityPath
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity

                $startGate.Dispose()
                $startGate = $null

                $postCloseDeadline = [DateTime]::UtcNow.AddSeconds(1)
                while (-not (Test-Path -LiteralPath $postGateMarkerPath) -and
                    $job.State -notin "Completed", "Failed", "Stopped" -and
                    [DateTime]::UtcNow -lt $postCloseDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                $preCleanupMessages = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
                $nativeMessage = $preCleanupMessages |
                    Where-Object Kind -eq "Native" |
                    Select-Object -First 1
                if ($nativeMessage) {
                    $nativeIdentity = $nativeMessage.Value
                    $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeIdentity
                }
                Assert-True `
                    (-not (Test-Path -LiteralPath $postGateMarkerPath)) `
                    "Post-gate path started before the first timer tick."
                Assert-True `
                    (-not $nativeMessage) `
                    "Native work started before the first timer tick."

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -WorkerIdentityPath $identityPath `
                    -UiDeadlineMilliseconds 1500
                $stopwatch.Stop()

                Assert-True ($stopwatch.ElapsedMilliseconds -le 2000) "Pre-tick UI stop took $($stopwatch.ElapsedMilliseconds) ms."
                Assert-True (-not $ticket.WorkerIdentity) "Pre-tick UI stop performed deferred identity discovery."
                Assert-True (-not $ticket.ProcessGroup) "Pre-tick UI stop attached a process group."
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Pre-tick worker"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Pre-tick deferred cleanup did not remove the job."

                $job = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - close before first tick"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture `
                    -Job $job `
                    -WorkerHandle $workerHandle `
                    -NativeHandle $nativeHandle `
                    -WorkerIdentity $workerIdentity `
                    -NativeIdentity $nativeIdentity
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $postGateMarkerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Terminal job and mismatched creation time do not kill an unrelated process"
        Run = {
            $job = $null
            $unrelatedProcess = $null
            $unrelatedHandle = $null

            try {
                $job = Start-Job { "done" }
                Wait-Job -Job $job -Timeout 5 | Out-Null
                Assert-True ($job.State -eq "Completed") "Expected terminal fixture job."
                $unrelatedProcess = Start-HiddenLifecycleNativeProcess -FilePath $nativeExe
                Assert-True $unrelatedProcess.StartInfo.CreateNoWindow "PID-reuse fixture was not launched with CreateNoWindow."
                Assert-True (-not $unrelatedProcess.StartInfo.UseShellExecute) "PID-reuse fixture unexpectedly used the shell."
                $unrelatedIdentity = [pscustomobject]@{
                    Id = $unrelatedProcess.Id
                    CreationFileTimeUtc = $unrelatedProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
                }
                $unrelatedHandle = New-LifecycleTestProcessHandle -Identity $unrelatedIdentity
                $wrongIdentity = [pscustomobject]@{
                    Id = $unrelatedIdentity.Id
                    CreationFileTimeUtc = $unrelatedIdentity.CreationFileTimeUtc + 1
                }
                $fakeGroup = [pscustomobject]@{
                    TerminateCalls = 0
                    DisposeCalls = 0
                }
                $fakeGroup | Add-Member ScriptMethod Terminate { $this.TerminateCalls++ }
                $fakeGroup | Add-Member ScriptMethod Dispose { $this.DisposeCalls++ }

                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -ProcessGroup $fakeGroup `
                    -WorkerIdentity $wrongIdentity `
                    -UiDeadlineMilliseconds 1500
                Assert-True ($fakeGroup.TerminateCalls -eq 0) "Terminal job process group was terminated."
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Terminal job was not removed."
                Assert-True (-not [TranscriptProcessTools]::TerminateTreeIfIdentityMatches(
                        [int]$wrongIdentity.Id,
                        [long]$wrongIdentity.CreationFileTimeUtc)) "Mismatched identity was accepted."
                Assert-True (-not $unrelatedHandle.HasExited) "Unrelated process was killed through PID reuse."

                $job = $null
                Write-Host "PASS terminal/PID-reuse safety"
            }
            finally {
                if ($unrelatedHandle) {
                    try { $unrelatedHandle.Terminate() } catch {}
                    try { [void]$unrelatedHandle.WaitForExit(3000) } catch {}
                    try { $unrelatedHandle.Dispose() } catch {}
                }
                if ($unrelatedProcess) { $unrelatedProcess.Dispose() }
                if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
            }
        }
    },
    @{
        Name = "Forced UI termination failure returns quickly and deferred cleanup succeeds"
        Run = {
            $job = $null
            $workerIdentity = $null
            $nativeIdentity = $null
            $workerHandle = $null
            $nativeHandle = $null
            $identityPath = Join-Path $tempRoot ("failure-" + [Guid]::NewGuid().ToString("N") + ".json")
            $postGateMarkerPath = Join-Path $tempRoot ("failure-post-gate-" + [Guid]::NewGuid().ToString("N"))
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName `
                    -PostGateMarkerPath $postGateMarkerPath
                $workerMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker"))
                $workerIdentity = ($workerMessages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity
                [void]$startGate.Set()
                $startGate.Dispose()
                $startGate = $null
                $nativeMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native"))
                $nativeIdentity = ($nativeMessages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value
                $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeIdentity
                $failingGroup = [pscustomobject]@{
                    TerminateCalls = 0
                    DisposeCalls = 0
                }
                $failingGroup | Add-Member ScriptMethod Terminate {
                    $this.TerminateCalls++
                    throw "forced process-group termination failure"
                }
                $failingGroup | Add-Member ScriptMethod Dispose { $this.DisposeCalls++ }

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -ProcessGroup $failingGroup `
                    -WorkerIdentity $workerIdentity `
                    -WorkerIdentityPath $identityPath `
                    -UiDeadlineMilliseconds 1500
                $stopwatch.Stop()

                Assert-True ($stopwatch.ElapsedMilliseconds -lt 200) "Failed UI cleanup request took $($stopwatch.ElapsedMilliseconds) ms."
                Assert-True ($failingGroup.TerminateCalls -eq 0) "UI cleanup request called the failing terminator."
                Assert-True (-not $ticket.UiTerminationError) "UI cleanup request reported a termination it did not attempt."
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-True ($failingGroup.TerminateCalls -eq 1) "Deferred cleanup did not call the failing terminator exactly once."
                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Fallback worker"
                Assert-ProcessHandleExited -ProcessHandle $nativeHandle -Description "Fallback native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Fallback deferred cleanup did not remove the job."

                $job = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - forced failure/deferred cleanup"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture `
                    -Job $job `
                    -WorkerHandle $workerHandle `
                    -NativeHandle $nativeHandle `
                    -WorkerIdentity $workerIdentity `
                    -NativeIdentity $nativeIdentity
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $postGateMarkerPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Fallback exception still removes the job and identity handoff"
        Run = {
            $job = $null
            $workerIdentity = $null
            $nativeIdentity = $null
            $workerHandle = $null
            $nativeHandle = $null
            $realProcessGroup = $null
            $groupWrapper = $null
            $identityPath = Join-Path $tempRoot ("fallback-exception-" + [Guid]::NewGuid().ToString("N") + ".json")
            $postGateMarkerPath = Join-Path $tempRoot ("fallback-exception-post-gate-" + [Guid]::NewGuid().ToString("N"))
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName `
                    -PostGateMarkerPath $postGateMarkerPath
                $workerMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker"))
                $workerIdentity = ($workerMessages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $workerHandle = New-LifecycleTestProcessHandle -Identity $workerIdentity
                $realProcessGroup = New-TranscriptProcessGroup -WorkerIdentity $workerIdentity
                $groupWrapper = [pscustomobject]@{
                    Inner = $realProcessGroup
                    JobId = $job.Id
                    TerminateCalls = 0
                    DisposeCalls = 0
                    JobPresentAtDispose = $false
                }
                $groupWrapper | Add-Member ScriptMethod Terminate {
                    $this.TerminateCalls++
                    throw "forced process-group termination failure"
                }
                $groupWrapper | Add-Member ScriptMethod Dispose {
                    $this.DisposeCalls++
                    $this.JobPresentAtDispose = [bool](
                        Get-Job -Id $this.JobId -ErrorAction SilentlyContinue
                    )
                    $this.Inner.Dispose()
                }
                [void]$startGate.Set()
                $startGate.Dispose()
                $startGate = $null
                $nativeMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native"))
                $nativeIdentity = ($nativeMessages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value
                $nativeHandle = New-LifecycleTestProcessHandle -Identity $nativeIdentity

                $ticket = Request-TranscriptBackgroundJobStop `
                    -Job $job `
                    -ProcessGroup $groupWrapper `
                    -WorkerIdentity $workerIdentity `
                    -WorkerIdentityPath $identityPath `
                    -UiDeadlineMilliseconds 1500
                $treeTerminator = {
                    param($ignoredIdentity)

                    throw "injected process-tree fallback failure"
                }.GetNewClosure()

                $cleanupError = $null
                $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    Complete-TranscriptBackgroundJobCleanup `
                        -Ticket $ticket `
                        -TreeTerminator $treeTerminator
                }
                catch {
                    $cleanupError = $_
                }
                $cleanupStopwatch.Stop()

                Assert-True ([bool]$cleanupError) "Expected injected fallback exception to propagate after cleanup."
                Assert-True `
                    ($cleanupError.Exception.Message -match "injected process-tree fallback failure") `
                    "Unexpected fallback exception: $($cleanupError.Exception.Message)"
                Assert-True `
                    $groupWrapper.JobPresentAtDispose `
                    "Process group was disposed only after the PowerShell job was removed."
                Assert-True `
                    ($cleanupStopwatch.ElapsedMilliseconds -le 5000) `
                    "Fallback exception cleanup took $($cleanupStopwatch.ElapsedMilliseconds) ms."
                Assert-ProcessHandleExited -ProcessHandle $workerHandle -Description "Injected-failure worker"
                Assert-ProcessHandleExited -ProcessHandle $nativeHandle -Description "Injected-failure native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Fallback exception skipped job removal."
                Assert-True (-not (Test-Path -LiteralPath $identityPath)) "Fallback exception skipped identity cleanup."
                Assert-True ($groupWrapper.DisposeCalls -eq 1) "Fallback exception skipped process-group disposal."

                $realProcessGroup = $null
                $groupWrapper = $null
                $job = $null
                Write-Host "PASS $($cleanupStopwatch.ElapsedMilliseconds) ms - fallback exception cleanup"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture `
                    -Job $job `
                    -ProcessGroup $groupWrapper `
                    -WorkerHandle $workerHandle `
                    -NativeHandle $nativeHandle `
                    -WorkerIdentity $workerIdentity `
                    -NativeIdentity $nativeIdentity
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $postGateMarkerPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
)

$passed = 0
try {
    foreach ($test in $tests) {
        & $test.Run
        $passed++
    }

    Write-Host "$passed/$($tests.Count) GUI lifecycle tests passed."
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
