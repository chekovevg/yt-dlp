$ErrorActionPreference = "Stop"

function Stop-TranscriptProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId,

        [ValidateRange(100, 10000)]
        [int]$TimeoutMilliseconds = 1500
    )

    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        return
    }

    $taskKillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $taskKillPath
    $startInfo.Arguments = "/PID $ProcessId /T /F"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $taskKill = New-Object System.Diagnostics.Process
    $taskKill.StartInfo = $startInfo

    try {
        if ($taskKill.Start()) {
            if (-not $taskKill.WaitForExit($TimeoutMilliseconds)) {
                $taskKill.Kill()
                $taskKill.WaitForExit()
            }
        }
    }
    finally {
        $taskKill.Dispose()
    }

    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        return
    }

    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $descendantIds = New-Object System.Collections.Generic.List[int]
    $pendingParentIds = New-Object System.Collections.Generic.Queue[int]
    $pendingParentIds.Enqueue($ProcessId)

    while ($pendingParentIds.Count -gt 0) {
        $parentId = $pendingParentIds.Dequeue()
        foreach ($child in $processes | Where-Object ParentProcessId -eq $parentId) {
            $childId = [int]$child.ProcessId
            $descendantIds.Add($childId)
            $pendingParentIds.Enqueue($childId)
        }
    }

    for ($index = $descendantIds.Count - 1; $index -ge 0; $index--) {
        Stop-Process -Id $descendantIds[$index] -Force -ErrorAction SilentlyContinue
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-TranscriptBackgroundJob {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Job]$Job,

        [int]$WorkerProcessId,

        [ValidateRange(100, 10000)]
        [int]$TimeoutMilliseconds = 1500
    )

    if ($WorkerProcessId -gt 0) {
        Stop-TranscriptProcessTree `
            -ProcessId $WorkerProcessId `
            -TimeoutMilliseconds $TimeoutMilliseconds
    }

    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}
