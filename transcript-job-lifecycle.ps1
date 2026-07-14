$ErrorActionPreference = "Stop"

if (-not ("TranscriptFileCleanupTools" -as [type])) {
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) "transcript-tool.psm1") -Force
}

if (-not ("TranscriptJobProcessGroup" -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class TranscriptJobProcessGroup : IDisposable
{
    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint PROCESS_SET_QUOTA = 0x0100;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    private IntPtr jobHandle;

    public int WorkerProcessId { get; private set; }
    public long WorkerCreationFileTimeUtc { get; private set; }

    private TranscriptJobProcessGroup(IntPtr jobHandle, int processId, long creationFileTimeUtc)
    {
        this.jobHandle = jobHandle;
        WorkerProcessId = processId;
        WorkerCreationFileTimeUtc = creationFileTimeUtc;
    }

    public static TranscriptJobProcessGroup Attach(int processId, long creationFileTimeUtc)
    {
        IntPtr processHandle = OpenProcess(
            PROCESS_TERMINATE | PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            false,
            processId);
        if (processHandle == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open transcript worker process.");
        }

        IntPtr newJobHandle = IntPtr.Zero;
        try
        {
            if (!TranscriptProcessTools.ProcessIdentityMatches(processHandle, creationFileTimeUtc))
            {
                throw new InvalidOperationException("Transcript worker process identity changed before it could be grouped.");
            }

            newJobHandle = CreateJobObject(IntPtr.Zero, null);
            if (newJobHandle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create transcript process group.");
            }

            ConfigureKillOnClose(newJobHandle);

            if (!AssignProcessToJobObject(newJobHandle, processHandle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not assign transcript worker to its process group.");
            }

            TranscriptJobProcessGroup group = new TranscriptJobProcessGroup(
                newJobHandle,
                processId,
                creationFileTimeUtc);
            newJobHandle = IntPtr.Zero;
            return group;
        }
        finally
        {
            CloseHandle(processHandle);
            if (newJobHandle != IntPtr.Zero)
            {
                CloseHandle(newJobHandle);
            }
        }
    }

    public void Terminate()
    {
        if (jobHandle == IntPtr.Zero)
        {
            throw new ObjectDisposedException("TranscriptJobProcessGroup");
        }

        if (!TerminateJobObject(jobHandle, 1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not terminate transcript process group.");
        }
    }

    public void Dispose()
    {
        IntPtr handle = jobHandle;
        jobHandle = IntPtr.Zero;
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
        }
    }

    private static void ConfigureKillOnClose(IntPtr handle)
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr pointer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(information, pointer, false);
            if (!SetInformationJobObject(handle, 9, pointer, (uint)size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure transcript process group.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}

public static class TranscriptProcessTools
{
    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    private const uint WAIT_OBJECT_0 = 0x00000000;

    public static bool TerminateTreeIfIdentityMatches(int processId, long creationFileTimeUtc)
    {
        IntPtr rootHandle = OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            false,
            processId);
        if (rootHandle == IntPtr.Zero)
        {
            return false;
        }

        List<IntPtr> descendantHandles = new List<IntPtr>();
        try
        {
            if (!ProcessIdentityMatches(rootHandle, creationFileTimeUtc))
            {
                return false;
            }

            if (WaitForSingleObject(rootHandle, 0) == WAIT_OBJECT_0)
            {
                return false;
            }

            ProcessTreeSnapshot snapshot = GetDescendantProcessSnapshot(processId);
            foreach (int descendantId in snapshot.DescendantIds)
            {
                IntPtr descendantHandle = OpenProcess(
                    PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                    false,
                    descendantId);
                if (descendantHandle != IntPtr.Zero)
                {
                    long descendantCreationFileTimeUtc;
                    if (TryGetProcessCreationFileTime(descendantHandle, out descendantCreationFileTimeUtc) &&
                        descendantCreationFileTimeUtc <= snapshot.CapturedAtFileTimeUtc &&
                        WaitForSingleObject(descendantHandle, 0) != WAIT_OBJECT_0)
                    {
                        descendantHandles.Add(descendantHandle);
                    }
                    else
                    {
                        CloseHandle(descendantHandle);
                    }
                }
            }

            if (!ProcessIdentityMatches(rootHandle, creationFileTimeUtc) ||
                WaitForSingleObject(rootHandle, 0) == WAIT_OBJECT_0)
            {
                return false;
            }

            for (int index = descendantHandles.Count - 1; index >= 0; index--)
            {
                TerminateProcess(descendantHandles[index], 1);
            }

            TerminateProcess(rootHandle, 1);
            WaitForSingleObject(rootHandle, 5000);
            return true;
        }
        finally
        {
            foreach (IntPtr handle in descendantHandles)
            {
                CloseHandle(handle);
            }
            CloseHandle(rootHandle);
        }
    }

    internal static bool ProcessIdentityMatches(IntPtr processHandle, long creationFileTimeUtc)
    {
        long actualCreationFileTime;
        if (!TryGetProcessCreationFileTime(processHandle, out actualCreationFileTime))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read transcript worker process identity.");
        }

        return actualCreationFileTime == creationFileTimeUtc;
    }

    private static bool TryGetProcessCreationFileTime(IntPtr processHandle, out long creationFileTimeUtc)
    {
        FILETIME creation;
        FILETIME exit;
        FILETIME kernel;
        FILETIME user;
        if (!GetProcessTimes(processHandle, out creation, out exit, out kernel, out user))
        {
            creationFileTimeUtc = 0;
            return false;
        }

        creationFileTimeUtc = ((long)creation.dwHighDateTime << 32) | creation.dwLowDateTime;
        return true;
    }

    private static ProcessTreeSnapshot GetDescendantProcessSnapshot(int rootProcessId)
    {
        long capturedAtFileTimeUtc = DateTime.UtcNow.ToFileTimeUtc();
        Dictionary<int, List<int>> childrenByParent = new Dictionary<int, List<int>>();
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not inspect transcript child processes.");
        }

        try
        {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32First(snapshot, ref entry))
            {
                do
                {
                    int parentId = unchecked((int)entry.th32ParentProcessID);
                    int childId = unchecked((int)entry.th32ProcessID);
                    List<int> children;
                    if (!childrenByParent.TryGetValue(parentId, out children))
                    {
                        children = new List<int>();
                        childrenByParent[parentId] = children;
                    }
                    children.Add(childId);
                }
                while (Process32Next(snapshot, ref entry));
            }
        }
        finally
        {
            CloseHandle(snapshot);
        }

        List<int> descendants = new List<int>();
        Queue<int> pending = new Queue<int>();
        pending.Enqueue(rootProcessId);
        while (pending.Count > 0)
        {
            int parentId = pending.Dequeue();
            List<int> children;
            if (!childrenByParent.TryGetValue(parentId, out children))
            {
                continue;
            }

            foreach (int childId in children)
            {
                descendants.Add(childId);
                pending.Enqueue(childId);
            }
        }

        return new ProcessTreeSnapshot(capturedAtFileTimeUtc, descendants);
    }

    private sealed class ProcessTreeSnapshot
    {
        public long CapturedAtFileTimeUtc { get; private set; }
        public List<int> DescendantIds { get; private set; }

        public ProcessTreeSnapshot(long capturedAtFileTimeUtc, List<int> descendantIds)
        {
            CapturedAtFileTimeUtc = capturedAtFileTimeUtc;
            DescendantIds = descendantIds;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
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
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Test-TranscriptJobTerminal {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Job]$Job)

    return $Job.State -in "Completed", "Failed", "Stopped", "Disconnected"
}

function Get-TranscriptWorkerIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $processId = [int]$saved.Id
        $creationFileTimeUtc = [long]$saved.CreationFileTimeUtc
        if ($processId -le 0 -or $creationFileTimeUtc -le 0) {
            return $null
        }

        return [pscustomobject]@{
            Id = $processId
            CreationFileTimeUtc = $creationFileTimeUtc
        }
    }
    catch {
        return $null
    }
}

function New-TranscriptProcessGroup {
    param([Parameter(Mandatory = $true)][object]$WorkerIdentity)

    [TranscriptJobProcessGroup]::Attach(
        [int]$WorkerIdentity.Id,
        [long]$WorkerIdentity.CreationFileTimeUtc
    )
}

function Remove-TranscriptDeferredOperationFiles {
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory,
        [Parameter(Mandatory = $true)][string]$StagingRoot
    )

    if ($OperationId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "Invalid transcript cleanup operation id."
    }

    $expectedTemporary = [System.IO.Path]::GetFullPath(
        (Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + $OperationId.ToLowerInvariant()))
    )
    $actualTemporary = [System.IO.Path]::GetFullPath($TemporaryDirectory)
    if ($actualTemporary -ne $expectedTemporary) {
        throw "Transcript temporary cleanup path did not match its operation id."
    }

    $expectedStaging = [System.IO.Path]::GetFullPath(
        (Join-Path $OutputDir (".youtube-transcript-operation-" + $OperationId.ToLowerInvariant()))
    )
    $actualStaging = [System.IO.Path]::GetFullPath($StagingRoot)
    if ($actualStaging -ne $expectedStaging) {
        throw "Transcript staging cleanup path did not match its operation id."
    }

    if (Test-Path -LiteralPath $actualStaging) {
        $outputRoot = [System.IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
        foreach ($publication in @(Get-ChildItem -LiteralPath $actualStaging -Directory -Filter "publication-*" -ErrorAction Stop)) {
            $commitPath = Join-Path $publication.FullName "commit.marker"
            $manifestPath = Join-Path $publication.FullName "manifest.json"
            if (-not (Test-Path -LiteralPath $commitPath) -and (Test-Path -LiteralPath $manifestPath)) {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
                foreach ($entry in @($manifest.Entries)) {
                    $target = [System.IO.Path]::GetFullPath([string]$entry.TargetPath)
                    if ((Split-Path -Parent $target).TrimEnd('\') -ne $outputRoot) {
                        throw "Transcript cleanup manifest escaped the output directory."
                    }
                    [void][TranscriptFileCleanupTools]::DeleteIfIdentityMatches(
                        $target,
                        [string]$entry.Identity
                    )
                }
            }
        }
        Remove-Item -LiteralPath $actualStaging -Recurse -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $actualTemporary) {
        Remove-Item -LiteralPath $actualTemporary -Recurse -Force -ErrorAction Stop
    }
}

function Request-TranscriptBackgroundJobStop {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Job]$Job,

        [object]$ProcessGroup,

        [object]$WorkerIdentity,

        [string]$WorkerIdentityPath,

        [string]$OperationId,

        [string]$OutputDir,

        [string]$TemporaryDirectory,

        [string]$StagingRoot,

        [ValidateRange(100, 2000)]
        [int]$UiDeadlineMilliseconds = 1500
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $wasTerminal = Test-TranscriptJobTerminal -Job $Job
    $stopwatch.Stop()
    return [pscustomobject]@{
        Job = $Job
        ProcessGroup = $ProcessGroup
        WorkerIdentity = $WorkerIdentity
        WorkerIdentityPath = $WorkerIdentityPath
        OperationId = $OperationId
        OutputDir = $OutputDir
        TemporaryDirectory = $TemporaryDirectory
        StagingRoot = $StagingRoot
        WasTerminal = $wasTerminal
        UiTerminationSucceeded = $false
        UiTerminationError = $null
        UiElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
    }
}

function Complete-TranscriptBackgroundJobCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Ticket,

        [scriptblock]$TreeTerminator = {
            param($WorkerIdentity)

            [TranscriptProcessTools]::TerminateTreeIfIdentityMatches(
                [int]$WorkerIdentity.Id,
                [long]$WorkerIdentity.CreationFileTimeUtc
            )
        }
    )

    $job = $Ticket.Job
    $group = $Ticket.ProcessGroup
    $identity = $Ticket.WorkerIdentity
    $cleanupError = $null
    $disposeError = $null
    $removeJobError = $null
    $operationCleanupError = $null

    try {
        if (-not $Ticket.WasTerminal -and -not (Test-TranscriptJobTerminal -Job $job)) {
            if (-not $identity -and $Ticket.WorkerIdentityPath) {
                $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not $identity -and
                    -not (Test-TranscriptJobTerminal -Job $job) -and
                    [DateTime]::UtcNow -lt $identityDeadline) {
                    $identity = Get-TranscriptWorkerIdentity -Path $Ticket.WorkerIdentityPath
                    if (-not $identity) {
                        Start-Sleep -Milliseconds 25
                    }
                }
            }

            if (-not $group -and $identity -and
                -not (Test-TranscriptJobTerminal -Job $job)) {
                try {
                    $group = New-TranscriptProcessGroup -WorkerIdentity $identity
                }
                catch {
                    $group = $null
                }
            }

            $terminated = [bool]$Ticket.UiTerminationSucceeded

            if (-not $terminated -and $group) {
                try {
                    $group.Terminate()
                    $terminated = $true
                }
                catch {
                    $terminated = $false
                }
            }

            if (-not $terminated -and $identity) {
                $null = & $TreeTerminator $identity
            }
        }
    }
    catch {
        $cleanupError = $_
    }
    finally {
        if ($group) {
            try {
                $group.Dispose()
            }
            catch {
                $disposeError = $_
            }
        }

        try {
            Remove-Job -Job $job -Force -ErrorAction Stop
        }
        catch {
            $removeJobError = $_
        }
        finally {
            if ($Ticket.WorkerIdentityPath) {
                try {
                    if (Test-Path -LiteralPath $Ticket.WorkerIdentityPath) {
                        Remove-Item `
                            -LiteralPath $Ticket.WorkerIdentityPath `
                            -Force `
                            -ErrorAction Stop
                    }
                }
                catch {
                    if (-not $disposeError) {
                        $disposeError = $_
                    }
                }
            }
        }

        if ($Ticket.OperationId -and $Ticket.OutputDir -and
            $Ticket.TemporaryDirectory -and $Ticket.StagingRoot) {
            try {
                Remove-TranscriptDeferredOperationFiles `
                    -OperationId $Ticket.OperationId `
                    -OutputDir $Ticket.OutputDir `
                    -TemporaryDirectory $Ticket.TemporaryDirectory `
                    -StagingRoot $Ticket.StagingRoot
            }
            catch {
                $operationCleanupError = $_
            }
        }
    }

    if ($cleanupError) {
        throw $cleanupError
    }

    if ($disposeError) {
        throw $disposeError
    }

    if ($removeJobError) {
        throw $removeJobError
    }

    if ($operationCleanupError) {
        throw $operationCleanupError
    }
}
