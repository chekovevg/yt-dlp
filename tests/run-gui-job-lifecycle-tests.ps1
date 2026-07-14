$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$lifecyclePath = Join-Path $root "transcript-job-lifecycle.ps1"

if (-not (Test-Path -LiteralPath $lifecyclePath)) {
    throw "GUI job lifecycle helper is missing: $lifecyclePath"
}

. $lifecyclePath

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

function Start-LifecycleFixtureJob {
    param(
        [Parameter(Mandatory = $true)][string]$NativeExe,
        [Parameter(Mandatory = $true)][string]$WorkerIdentityPath,
        [string]$StartGateName
    )

    Start-Job -ArgumentList @($NativeExe, $WorkerIdentityPath, $StartGateName) -ScriptBlock {
        param($nativeExe, $workerIdentityPath, $startGateName)

        $workerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        $workerIdentity = [pscustomobject]@{
            Id = $PID
            CreationFileTimeUtc = $workerProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        }
        [System.IO.File]::WriteAllText(
            $workerIdentityPath,
            ($workerIdentity | ConvertTo-Json -Compress)
        )

        [pscustomobject]@{
            Kind = "Worker"
            Value = $workerIdentity
        }

        if ($startGateName) {
            $startGate = [System.Threading.EventWaitHandle]::OpenExisting($startGateName)
            try {
                [void]$startGate.WaitOne()
            }
            finally {
                $startGate.Dispose()
            }
        }

        $nativeProcess = Start-Process -FilePath $nativeExe -PassThru
        [pscustomobject]@{
            Kind = "Native"
            Value = $nativeProcess.Id
        }
        $nativeProcess.WaitForExit()
    }
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
        [object]$WorkerIdentity,
        [int]$NativeProcessId
    )

    if ($ProcessGroup) {
        try { $ProcessGroup.Terminate() } catch {}
        try { $ProcessGroup.Dispose() } catch {}
    }

    if (-not $WorkerIdentity -and $Job) {
        $workerMessage = $Job.ChildJobs[0].Output |
            Where-Object Kind -eq "Worker" |
            Select-Object -First 1
        if ($workerMessage) {
            $WorkerIdentity = $workerMessage.Value
        }
    }

    if ($WorkerIdentity) {
        $workerProcessId = [int]$WorkerIdentity.Id
        Stop-Process -Id $workerProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($NativeProcessId) {
        Stop-Process -Id $NativeProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($Job) {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline -and (
                ($WorkerIdentity -and (Get-Process -Id ([int]$WorkerIdentity.Id) -ErrorAction SilentlyContinue)) -or
                ($NativeProcessId -and (Get-Process -Id $NativeProcessId -ErrorAction SilentlyContinue)) -or
                $Job.State -notin "Completed", "Failed", "Stopped")) {
            Start-Sleep -Milliseconds 25
        }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ProcessExited {
    param(
        [int]$ProcessId,
        [string]$Description
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ([DateTime]::UtcNow -lt $deadline -and
        (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 25
    }

    Assert-True `
        (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) `
        "$Description process $ProcessId survived cleanup."
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
            $nativeProcessId = 0
            $identityPath = Join-Path $tempRoot ("active-" + [Guid]::NewGuid().ToString("N") + ".json")
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName
                $workerMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker"))
                $workerIdentity = ($workerMessages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $processGroup = New-TranscriptProcessGroup -WorkerIdentity $workerIdentity
                [void]$startGate.Set()
                $startGate.Dispose()
                $startGate = $null

                $nativeMessages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Native"))
                $nativeProcessId = [int](($nativeMessages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value)
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
                Assert-ProcessExited -ProcessId ([int]$workerIdentity.Id) -Description "Worker"
                Assert-ProcessExited -ProcessId $nativeProcessId -Description "Native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Deferred cleanup did not remove the job."

                $job = $null
                $processGroup = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - active native child"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture -Job $job -ProcessGroup $processGroup -WorkerIdentity $workerIdentity -NativeProcessId $nativeProcessId
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Close before first timer tick cannot start native work"
        Run = {
            $job = $null
            $workerIdentity = $null
            $identityPath = Join-Path $tempRoot ("pretick-" + [Guid]::NewGuid().ToString("N") + ".json")
            $gateName = "Local\TranscriptLifecycle-" + [Guid]::NewGuid().ToString("N")
            $startGate = New-StartGate -Name $gateName

            try {
                $job = Start-LifecycleFixtureJob `
                    -NativeExe $nativeExe `
                    -WorkerIdentityPath $identityPath `
                    -StartGateName $gateName
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $identityPath) -and [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (Test-Path -LiteralPath $identityPath) "Worker identity handoff was not written."
                $workerIdentity = Get-TranscriptWorkerIdentity -Path $identityPath

                $startGate.Dispose()
                $startGate = $null
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
                Assert-ProcessExited -ProcessId ([int]$workerIdentity.Id) -Description "Pre-tick worker"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Pre-tick deferred cleanup did not remove the job."

                $job = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - close before first tick"
            }
            finally {
                if ($startGate) { $startGate.Dispose() }
                Stop-LifecycleFixture -Job $job -WorkerIdentity $workerIdentity
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = "Terminal job and mismatched creation time do not kill an unrelated process"
        Run = {
            $job = $null
            $unrelatedProcess = $null

            try {
                $job = Start-Job { "done" }
                Wait-Job -Job $job -Timeout 5 | Out-Null
                Assert-True ($job.State -eq "Completed") "Expected terminal fixture job."
                $unrelatedProcess = Start-Process -FilePath $nativeExe -PassThru
                $wrongIdentity = [pscustomobject]@{
                    Id = $unrelatedProcess.Id
                    CreationFileTimeUtc = $unrelatedProcess.StartTime.ToUniversalTime().ToFileTimeUtc() + 1
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
                Assert-True (-not $unrelatedProcess.HasExited) "Unrelated process was killed through PID reuse."

                $job = $null
                Write-Host "PASS terminal/PID-reuse safety"
            }
            finally {
                if ($unrelatedProcess -and -not $unrelatedProcess.HasExited) {
                    Stop-Process -Id $unrelatedProcess.Id -Force -ErrorAction SilentlyContinue
                }
                if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
            }
        }
    },
    @{
        Name = "Forced UI termination failure returns quickly and deferred cleanup succeeds"
        Run = {
            $job = $null
            $workerIdentity = $null
            $nativeProcessId = 0
            $identityPath = Join-Path $tempRoot ("failure-" + [Guid]::NewGuid().ToString("N") + ".json")

            try {
                $job = Start-LifecycleFixtureJob -NativeExe $nativeExe -WorkerIdentityPath $identityPath
                $messages = @(Receive-LifecycleMessages -Job $job -RequiredKinds @("Worker", "Native"))
                $workerIdentity = ($messages | Where-Object Kind -eq "Worker" | Select-Object -First 1).Value
                $nativeProcessId = [int](($messages | Where-Object Kind -eq "Native" | Select-Object -First 1).Value)
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

                Assert-True ($stopwatch.ElapsedMilliseconds -le 2000) "Failed UI cleanup path took $($stopwatch.ElapsedMilliseconds) ms."
                Assert-True ([bool]$ticket.UiTerminationError) "Expected the forced UI termination error on the cleanup ticket."
                Complete-TranscriptBackgroundJobCleanup -Ticket $ticket
                Assert-ProcessExited -ProcessId ([int]$workerIdentity.Id) -Description "Fallback worker"
                Assert-ProcessExited -ProcessId $nativeProcessId -Description "Fallback native"
                Assert-True (-not (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) "Fallback deferred cleanup did not remove the job."

                $job = $null
                Write-Host "PASS $($stopwatch.ElapsedMilliseconds) ms - forced failure/deferred cleanup"
            }
            finally {
                Stop-LifecycleFixture -Job $job -WorkerIdentity $workerIdentity -NativeProcessId $nativeProcessId
                Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
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
