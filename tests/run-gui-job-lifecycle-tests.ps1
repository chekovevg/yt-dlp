$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$lifecyclePath = Join-Path $root "transcript-job-lifecycle.ps1"

if (-not (Test-Path -LiteralPath $lifecyclePath)) {
    throw "GUI job lifecycle helper is missing: $lifecyclePath"
}

. $lifecyclePath

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("transcript-job-lifecycle-" + [Guid]::NewGuid().ToString("N"))
$nativeExe = Join-Path $tempRoot "slow-native.exe"
$job = $null
$workerProcessId = 0
$nativeProcessId = 0

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

try {
    $job = Start-Job -ArgumentList @($nativeExe) -ScriptBlock {
        param($nativeExe)

        [pscustomobject]@{
            Kind = "Worker"
            Value = $PID
        }

        $nativeProcess = Start-Process -FilePath $nativeExe -PassThru
        [pscustomobject]@{
            Kind = "Native"
            Value = $nativeProcess.Id
        }

        $nativeProcess.WaitForExit()
    }

    $messages = @()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while ($messages.Count -lt 2 -and [DateTime]::UtcNow -lt $deadline) {
        $messages += @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        if ($messages.Count -lt 2) {
            Start-Sleep -Milliseconds 50
        }
    }

    $workerProcessId = [int](($messages |
        Where-Object Kind -eq "Worker" |
        Select-Object -First 1).Value)
    $nativeProcessId = [int](($messages |
        Where-Object Kind -eq "Native" |
        Select-Object -First 1).Value)

    if (-not $workerProcessId -or -not $nativeProcessId) {
        throw "Expected worker and native process IDs from the lifecycle fixture."
    }

    if ($job.State -ne "Running") {
        throw "Expected the lifecycle fixture job to be running, got $($job.State)."
    }

    $jobId = $job.Id
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-TranscriptBackgroundJob `
        -Job $job `
        -WorkerProcessId $workerProcessId `
        -TimeoutMilliseconds 1500

    while ($stopwatch.ElapsedMilliseconds -lt 2000 -and (
            (Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue) -or
            (Get-Process -Id $nativeProcessId -ErrorAction SilentlyContinue))) {
        Start-Sleep -Milliseconds 25
    }
    $stopwatch.Stop()

    if ($stopwatch.ElapsedMilliseconds -gt 2000) {
        throw "Lifecycle cleanup took $($stopwatch.ElapsedMilliseconds) ms; expected at most 2000 ms."
    }

    if (Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue) {
        throw "Background worker process $workerProcessId survived lifecycle cleanup."
    }

    if (Get-Process -Id $nativeProcessId -ErrorAction SilentlyContinue) {
        throw "Native child process $nativeProcessId survived lifecycle cleanup."
    }

    if (Get-Job -Id $jobId -ErrorAction SilentlyContinue) {
        throw "Background job $jobId survived lifecycle cleanup."
    }

    $job = $null
    Write-Host "PASS: active GUI job process tree stopped and job removed in $($stopwatch.ElapsedMilliseconds) ms."
}
finally {
    if ($job) {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    if ($workerProcessId) {
        Stop-Process -Id $workerProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($nativeProcessId) {
        Stop-Process -Id $nativeProcessId -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
