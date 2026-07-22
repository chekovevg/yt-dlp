$script:MinimumYtDlpVersion = [version]"2026.7.4"
$script:ValidatedYtDlpVersions = @{}

if (-not ("TranscriptFileCleanupTools" -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

public static class TranscriptFileCleanupTools
{
    private const uint DELETE = 0x00010000;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    public static FileStream OpenDeleteOnCloseLock(string path)
    {
        return new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.Read,
            1,
            FileOptions.DeleteOnClose);
    }

    public static string GetIdentity(string path)
    {
        IntPtr handle = OpenIdentityHandle(path, FILE_READ_ATTRIBUTES);
        try { return ReadIdentity(handle); }
        finally { CloseHandle(handle); }
    }

    public static bool DeleteIfIdentityMatches(string path, string expectedIdentity)
    {
        IntPtr handle = CreateFile(
            path,
            DELETE | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE)
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3) { return false; }
            throw new Win32Exception(error, "Could not open transcript output for identity-safe cleanup.");
        }

        try
        {
            if (!String.Equals(ReadIdentity(handle), expectedIdentity, StringComparison.Ordinal))
            {
                return false;
            }

            FILE_DISPOSITION_INFO disposition = new FILE_DISPOSITION_INFO();
            disposition.DeleteFile = true;
            if (!SetFileInformationByHandle(
                handle,
                4,
                ref disposition,
                (uint)Marshal.SizeOf(typeof(FILE_DISPOSITION_INFO))))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not remove matching transcript output.");
            }
            return true;
        }
        finally { CloseHandle(handle); }
    }

    public static void KillProcessTree(int rootProcessId)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not inspect the timed-out process tree.");
        }

        List<PROCESSENTRY32> entries = new List<PROCESSENTRY32>();
        try
        {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32First(snapshot, ref entry))
            {
                do
                {
                    entries.Add(entry);
                    entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                }
                while (Process32Next(snapshot, ref entry));
            }
        }
        finally { CloseHandle(snapshot); }

        List<int> tree = new List<int>();
        tree.Add(rootProcessId);
        bool added;
        do
        {
            added = false;
            foreach (PROCESSENTRY32 entry in entries)
            {
                int processId = unchecked((int)entry.th32ProcessID);
                int parentId = unchecked((int)entry.th32ParentProcessID);
                if (!tree.Contains(processId) && tree.Contains(parentId))
                {
                    tree.Add(processId);
                    added = true;
                }
            }
        }
        while (added);

        for (int index = tree.Count - 1; index >= 0; index--)
        {
            try
            {
                using (Process process = Process.GetProcessById(tree[index]))
                {
                    process.Kill();
                }
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
        }
    }

    private static IntPtr OpenIdentityHandle(string path, uint access)
    {
        IntPtr handle = CreateFile(
            path,
            access,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read transcript staging identity.");
        }
        return handle;
    }

    private static string ReadIdentity(IntPtr handle)
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read transcript file identity.");
        }
        ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        return information.VolumeSerialNumber.ToString("X8") + ":" + index.ToString("X16");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool DeleteFile;
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file,
        out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(
        IntPtr file,
        int informationClass,
        ref FILE_DISPOSITION_INFO information,
        uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Get-TranscriptToolRoot {
    Split-Path -Parent $PSCommandPath
}

function Get-TranscriptSettingsPath {
    $dir = Join-Path $env:APPDATA "YouTubeTranscriptTool"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Join-Path $dir "settings.json"
}

function Get-DefaultTranscriptSettings {
    [pscustomobject]@{
        OutputDir = Join-Path (Get-TranscriptToolRoot) "texts"
        KeepSubtitles = $false
    }
}

function Read-TranscriptSettings {
    $defaults = Get-DefaultTranscriptSettings
    $path = Get-TranscriptSettingsPath

    if (-not (Test-Path -LiteralPath $path)) {
        return $defaults
    }

    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json

        if ($saved.OutputDir) {
            $defaults.OutputDir = [string]$saved.OutputDir
        }

        $defaults.KeepSubtitles = [bool]$saved.KeepSubtitles
    }
    catch {
        return $defaults
    }

    return $defaults
}

function Write-TranscriptSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$KeepSubtitles
    )

    $settings = [pscustomobject]@{
        OutputDir = $OutputDir
        KeepSubtitles = $KeepSubtitles
    }

    $settings | ConvertTo-Json | Set-Content -LiteralPath (Get-TranscriptSettingsPath) -Encoding utf8
}

function Get-YtDlpPath {
    param(
        [string]$PreferredPath
    )

    if ($PreferredPath) {
        if (-not (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) {
            throw "yt-dlp.exe was not found at the explicitly selected test path."
        }

        $resolvedPreferredPath = (Resolve-Path -LiteralPath $PreferredPath).Path
        Assert-YtDlpVersionContract -YtDlpPath $resolvedPreferredPath
        return $resolvedPreferredPath
    }

    $local = Join-Path (Get-TranscriptToolRoot) "yt-dlp.exe"
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        $resolvedLocalPath = (Resolve-Path -LiteralPath $local).Path
        Assert-YtDlpVersionContract -YtDlpPath $resolvedLocalPath
        return $resolvedLocalPath
    }

    throw "yt-dlp.exe was not found. Put the supported bundled yt-dlp.exe next to this tool."
}

function Get-ManagedYtDlpArguments {
    param(
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    return @("--ignore-config", "--no-plugin-dirs") + @($ArgumentList)
}

function Assert-YtDlpVersionText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $trimmed = $Version.Trim()
    if ($trimmed -notmatch '^(\d{4})\.(\d{2})\.(\d{2})$') {
        throw "UnsupportedYtDlpContract: yt-dlp 2026.07.04 or newer stable version is required."
    }

    try {
        $parsed = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    catch {
        throw "UnsupportedYtDlpContract: yt-dlp returned an invalid stable version."
    }

    if ($parsed -lt $script:MinimumYtDlpVersion) {
        throw "UnsupportedYtDlpContract: yt-dlp 2026.07.04 or newer stable version is required."
    }
}

function Assert-YtDlpVersionContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath
    )

    $cacheKey = [System.IO.Path]::GetFullPath($YtDlpPath).ToLowerInvariant()
    if ($script:ValidatedYtDlpVersions.ContainsKey($cacheKey)) {
        return
    }

    $result = Invoke-TranscriptProcess `
        -FilePath $YtDlpPath `
        -ArgumentList (Get-ManagedYtDlpArguments -ArgumentList @("--version")) `
        -TimeoutMilliseconds 10000
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        throw "UnsupportedYtDlpContract: could not verify the bundled yt-dlp version."
    }

    $version = @($result.StdOut -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
    Assert-YtDlpVersionText -Version ([string]$version)
    $script:ValidatedYtDlpVersions[$cacheKey] = [string]$version
}

function Test-YoutubeUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    return ($Url -match '^https?://(www\.)?(youtube\.com|youtu\.be)/')
}

function ConvertTo-NativeArgument {
    param(
        [AllowNull()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ""
    }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = New-Object System.Text.StringBuilder
    [void]$escaped.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashCount++
            continue
        }

        if ($character -eq [char]'"') {
            if ($backslashCount -gt 0) {
                [void]$escaped.Append((New-Object string ([char]'\'), ($backslashCount * 2)))
            }

            [void]$escaped.Append('\"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$escaped.Append((New-Object string ([char]'\'), $backslashCount))
            $backslashCount = 0
        }

        [void]$escaped.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$escaped.Append((New-Object string ([char]'\'), ($backslashCount * 2)))
    }

    [void]$escaped.Append('"')
    return $escaped.ToString()
}

function Invoke-TranscriptProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [string]$WorkingDirectory,

        [ValidateRange(0, 2147483647)]
        [int]$TimeoutMilliseconds = 0
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-NativeArgument -Argument $_ }) -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw "Could not start process: $FilePath"
        }

        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = $false

        if ($TimeoutMilliseconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                $timedOut = $true
                $taskkillPath = Join-Path ([System.Environment]::SystemDirectory) 'taskkill.exe'
                $nativeTreeKillSucceeded = $false

                try {
                    [TranscriptFileCleanupTools]::KillProcessTree($process.Id)
                    $nativeTreeKillSucceeded = $true
                }
                catch {
                    $nativeTreeKillSucceeded = $false
                }

                if (-not $nativeTreeKillSucceeded -and (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
                    $taskkillStartInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $taskkillStartInfo.FileName = $taskkillPath
                    $taskkillStartInfo.Arguments = "/PID $($process.Id) /T /F"
                    $taskkillStartInfo.UseShellExecute = $false
                    $taskkillStartInfo.CreateNoWindow = $true

                    $taskkillProcess = New-Object System.Diagnostics.Process
                    $taskkillProcess.StartInfo = $taskkillStartInfo

                    try {
                        if ($taskkillProcess.Start()) {
                            if (-not $taskkillProcess.WaitForExit(5000)) {
                                $taskkillProcess.Kill()
                                [void]$taskkillProcess.WaitForExit(1000)
                            }
                        }
                    }
                    finally {
                        $taskkillProcess.Dispose()
                    }
                }

                if (-not $process.WaitForExit(2000)) {
                    $process.Kill()
                    [void]$process.WaitForExit(1000)
                }
            }
        }
        else {
            $process.WaitForExit()
        }

        $stdOut = if ($stdOutTask.Wait(1000)) { $stdOutTask.GetAwaiter().GetResult() } else { '' }
        $stdErr = if ($stdErrTask.Wait(1000)) { $stdErrTask.GetAwaiter().GetResult() } else { '' }
        $output = @($stdOut, $stdErr) |
            Where-Object { -not [string]::IsNullOrEmpty($_) }

        return [pscustomobject]@{
            ExitCode = if ($timedOut) { -1 } else { $process.ExitCode }
            TimedOut = $timedOut
            StdOut = $stdOut
            StdErr = $stdErr
            Output = ($output -join [System.Environment]::NewLine)
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-TranscriptWorkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkerScriptPath,

        [string[]]$ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $WorkerScriptPath -PathType Leaf)) {
        throw "Transcript worker script was not found: $WorkerScriptPath"
    }

    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $workerArguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $WorkerScriptPath
    ) + @($ArgumentList)

    $reportedError = $null
    $unparsedOutput = New-Object System.Collections.Generic.List[string]

    & $powershellPath @workerArguments 2>&1 |
        ForEach-Object {
            $line = [string]$_
            if ([string]::IsNullOrWhiteSpace($line)) {
                return
            }

            try {
                if (-not $line.StartsWith("TT1:", [System.StringComparison]::Ordinal)) {
                    throw "Missing transcript-worker protocol prefix."
                }

                $json = [System.Text.Encoding]::UTF8.GetString(
                    [Convert]::FromBase64String($line.Substring(4))
                )
                $message = $json | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                if ($unparsedOutput.Count -lt 20) {
                    $unparsedOutput.Add($line)
                }
                continue
            }

            switch ([string]$message.Kind) {
                "Status" { $message }
                "Result" { $message }
                "Error" {
                    if (-not $reportedError) {
                        $reportedError = [string]$message.Value
                    }
                }
                default {
                    if ($unparsedOutput.Count -lt 20) {
                        $unparsedOutput.Add($line)
                    }
                }
            }
        }

    $exitCode = $LASTEXITCODE

    if ($reportedError) {
        throw $reportedError
    }

    if ($exitCode -ne 0 -or $unparsedOutput.Count -gt 0) {
        $diagnostic = Get-BoundedTranscriptDiagnostic -Text (
            @($unparsedOutput) -join [System.Environment]::NewLine
        )

        if (-not $diagnostic) {
            $diagnostic = "exit code $exitCode"
        }

        throw "Transcript worker failed: $diagnostic"
    }
}

function Assert-YtDlpMetadataContract {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info
    )

    foreach ($propertyName in @("subtitles", "automatic_captions", "formats")) {
        if (-not $Info.PSObject.Properties[$propertyName]) {
            throw "UnsupportedYtDlpContract: metadata is missing '$propertyName'."
        }
    }

    foreach ($mapName in @("subtitles", "automatic_captions")) {
        $map = $Info.$mapName
        if ($null -eq $map) {
            continue
        }
        if ($map -isnot [pscustomobject]) {
            throw "UnsupportedYtDlpContract: metadata '$mapName' is not a language-track map."
        }

        foreach ($property in $map.PSObject.Properties) {
            if ($property.Value -isnot [System.Array]) {
                throw "UnsupportedYtDlpContract: metadata '$mapName.$($property.Name)' is not a format array."
            }
            foreach ($format in @($property.Value)) {
                if ($null -eq $format -or $format -isnot [pscustomobject]) {
                    throw "UnsupportedYtDlpContract: metadata '$mapName.$($property.Name)' contains an invalid format."
                }
            }
        }
    }

    if ($Info.formats -isnot [System.Array]) {
        throw "UnsupportedYtDlpContract: metadata 'formats' is not an array."
    }
    foreach ($format in @($Info.formats)) {
        if ($null -eq $format -or $format -isnot [pscustomobject]) {
            throw "UnsupportedYtDlpContract: metadata 'formats' contains an invalid entry."
        }
    }
}

function Invoke-YtDlpJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [ValidateRange(1, 2147483647)]
        [int]$TimeoutMilliseconds = 20000,

        [ValidateRange(1, 5)]
        [int]$MaxAttempts = 2
    )

    Assert-YtDlpVersionContract -YtDlpPath $YtDlpPath

    $result = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-TranscriptProcess `
            -FilePath $YtDlpPath `
            -ArgumentList (Get-ManagedYtDlpArguments -ArgumentList @('--skip-download', '--dump-single-json', '--no-warnings', '--no-playlist', $Url)) `
            -TimeoutMilliseconds $TimeoutMilliseconds

        if (-not $result.TimedOut) {
            break
        }

        if ($attempt -eq $MaxAttempts) {
            throw "Checking the YouTube link took too long. Please try again."
        }
    }

    if ($result.ExitCode -ne 0) {
        $fullMessage = ([string]$result.Output).Trim()
        $message = Get-BoundedTranscriptDiagnostic -Text $fullMessage

        if ($fullMessage -match "Unsupported URL|Invalid URL") {
            throw "The YouTube link looks invalid. Please paste a normal youtube.com or youtu.be video link."
        }

        if ($fullMessage -match "Private video|Video unavailable|This video is unavailable|Sign in") {
            throw "This video is unavailable without login or cannot be accessed by yt-dlp."
        }

        if ($fullMessage -match "HTTP Error 429|Too Many Requests|rate.?limit") {
            throw "YouTube temporarily rate-limited requests. Wait a little and try again."
        }

        if ($fullMessage -match "HTTP Error|Unable to download|Temporary failure|timed out|network") {
            throw "Network problem while checking the video. Try again in a few minutes."
        }

        throw "Could not read video information. yt-dlp said: $message"
    }

    try {
        $info = $result.StdOut | ConvertFrom-Json
        Assert-YtDlpMetadataContract -Info $info
        return $info
    }
    catch {
        if ($_.Exception.Message -match '^UnsupportedYtDlpContract:') {
            throw $_
        }
        throw "yt-dlp returned metadata that this tool could not read."
    }
}

function ConvertTo-TranscriptLanguageIdentity {
    param(
        [AllowNull()]
        [string]$RawTrackTag
    )

    if ([string]::IsNullOrWhiteSpace($RawTrackTag)) {
        return $null
    }

    $normalized = $RawTrackTag.Trim().Replace("_", "-")
    $canonicalInput = $normalized -replace '(?i)-orig$', ''
    if ($canonicalInput -notmatch '^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$') {
        return $null
    }

    $parts = @($canonicalInput -split '-')
    $base = $parts[0].ToLowerInvariant()
    if ($base -in @("und", "mul", "zxx")) {
        return $null
    }

    $canonicalParts = New-Object System.Collections.Generic.List[string]
    $canonicalParts.Add($base)
    for ($index = 1; $index -lt $parts.Count; $index++) {
        $part = $parts[$index]
        if ($part -match '^[A-Za-z]{4}$') {
            $canonicalParts.Add($part.Substring(0, 1).ToUpperInvariant() + $part.Substring(1).ToLowerInvariant())
        }
        elseif ($part -match '^[A-Za-z]{2}$' -or $part -match '^\d{3}$') {
            $canonicalParts.Add($part.ToUpperInvariant())
        }
        else {
            $canonicalParts.Add($part.ToLowerInvariant())
        }
    }

    return [pscustomobject]@{
        RawTrackTag = $RawTrackTag
        CanonicalLanguageTag = ($canonicalParts -join "-")
        BaseLanguage = $base
    }
}

function Get-TranscriptEligibleRepresentations {
    param(
        [AllowNull()]
        [object]$Formats
    )

    $eligible = foreach ($format in @($Formats)) {
        if (-not $format) {
            continue
        }

        $extension = ([string]$format.ext).Trim().ToLowerInvariant()
        if ($extension -notin @("vtt", "srt")) {
            continue
        }

        $uri = $null
        if (-not [System.Uri]::TryCreate(([string]$format.url).Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
            continue
        }
        if ($uri.Scheme -notin @("http", "https")) {
            continue
        }

        $protocol = ([string]$format.protocol).Trim().ToLowerInvariant()
        if ($protocol -and $protocol -notin @("http", "https")) {
            continue
        }

        [pscustomobject]@{
            Extension = $extension
            Url = $uri.AbsoluteUri
        }
    }

    return @($eligible | Sort-Object @{ Expression = { if ($_.Extension -eq "vtt") { 0 } else { 1 } } }, Url)
}

function Get-TranscriptSubtitleTracks {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info
    )

    $tracks = New-Object System.Collections.Generic.List[object]
    foreach ($sourceDefinition in @(
            [pscustomobject]@{ Map = $Info.subtitles; SourceKind = "Manual" },
            [pscustomobject]@{ Map = $Info.automatic_captions; SourceKind = "Automatic" }
        )) {
        if (-not $sourceDefinition.Map) {
            continue
        }

        foreach ($property in $sourceDefinition.Map.PSObject.Properties) {
            $identity = ConvertTo-TranscriptLanguageIdentity -RawTrackTag $property.Name
            $representations = @(Get-TranscriptEligibleRepresentations -Formats $property.Value)
            $sourceKind = if ($property.Name -eq "live_chat") {
                "ExcludedService"
            }
            elseif ($sourceDefinition.SourceKind -eq "Automatic" -and $property.Name -notmatch '(?i)-orig$') {
                "AutomaticUntrusted"
            }
            elseif ($sourceDefinition.SourceKind -eq "Automatic") {
                "AutomaticOriginal"
            }
            else {
                "Manual"
            }

            if (-not $identity -or $representations.Count -eq 0) {
                continue
            }

            $tracks.Add([pscustomobject]@{
                RawTrackTag = $identity.RawTrackTag
                CanonicalLanguageTag = $identity.CanonicalLanguageTag
                BaseLanguage = $identity.BaseLanguage
                SourceKind = $sourceKind
                PreferredExtension = $representations[0].Extension
                Representations = $representations
            })
        }
    }

    return @($tracks.ToArray())
}

function Get-TranscriptSubtitleInventory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info
    )

    Assert-YtDlpMetadataContract -Info $Info
    return @(
        Get-TranscriptSubtitleTracks -Info $Info |
            Sort-Object SourceKind, RawTrackTag
    )
}

function Get-TranscriptAudioLanguageIdentities {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info,

        [int]$LanguagePreference,

        [switch]$AnyNonDescriptive
    )

    $identities = foreach ($format in @($Info.formats)) {
        if (-not $format -or [string]::IsNullOrWhiteSpace([string]$format.acodec) -or ([string]$format.acodec) -eq "none") {
            continue
        }

        $preference = 0
        $hasPreference = [int]::TryParse([string]$format.language_preference, [ref]$preference)
        if ($AnyNonDescriptive) {
            if ($hasPreference -and $preference -eq -10) {
                continue
            }
        }
        elseif (-not $hasPreference -or $preference -ne $LanguagePreference) {
            continue
        }

        $identity = ConvertTo-TranscriptLanguageIdentity -RawTrackTag ([string]$format.language)
        if ($identity) {
            $identity
        }
    }

    return @($identities | Sort-Object CanonicalLanguageTag -Unique)
}

function Get-TranscriptOriginalLanguageEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Tracks
    )

    $automaticEvidence = @($Tracks |
        Where-Object SourceKind -eq "AutomaticOriginal" |
        Sort-Object CanonicalLanguageTag -Unique)
    $originalAudio = @(Get-TranscriptAudioLanguageIdentities -Info $Info -LanguagePreference 10)

    if ($automaticEvidence.Count -gt 1 -or $originalAudio.Count -gt 1) {
        throw "OriginalLanguageAmbiguous: multiple original-language signals were found."
    }
    if ($automaticEvidence.Count -eq 1 -and $originalAudio.Count -eq 1 -and
        $automaticEvidence[0].BaseLanguage -ne $originalAudio[0].BaseLanguage) {
        throw "OriginalLanguageAmbiguous: caption and audio evidence disagree."
    }

    if ($automaticEvidence.Count -eq 1) {
        return [pscustomobject]@{
            CanonicalLanguageTag = $automaticEvidence[0].CanonicalLanguageTag
            BaseLanguage = $automaticEvidence[0].BaseLanguage
            Tier = "AutomaticOriginal"
        }
    }
    if ($originalAudio.Count -eq 1) {
        return [pscustomobject]@{
            CanonicalLanguageTag = $originalAudio[0].CanonicalLanguageTag
            BaseLanguage = $originalAudio[0].BaseLanguage
            Tier = "OriginalAudio"
        }
    }

    $defaultAudio = @(Get-TranscriptAudioLanguageIdentities -Info $Info -LanguagePreference 5)
    if ($defaultAudio.Count -gt 1) {
        throw "OriginalLanguageAmbiguous: multiple default-audio languages were found."
    }
    if ($defaultAudio.Count -eq 1) {
        return [pscustomobject]@{
            CanonicalLanguageTag = $defaultAudio[0].CanonicalLanguageTag
            BaseLanguage = $defaultAudio[0].BaseLanguage
            Tier = "DefaultAudio"
        }
    }

    $otherAudio = @(Get-TranscriptAudioLanguageIdentities -Info $Info -AnyNonDescriptive)
    $otherBases = @($otherAudio | Select-Object -ExpandProperty BaseLanguage -Unique)
    if ($otherBases.Count -eq 1) {
        $sameBase = @($otherAudio | Where-Object BaseLanguage -eq $otherBases[0])
        return [pscustomobject]@{
            CanonicalLanguageTag = if ($sameBase.Count -eq 1) { $sameBase[0].CanonicalLanguageTag } else { $otherBases[0] }
            BaseLanguage = $otherBases[0]
            Tier = "UniqueAudio"
        }
    }
    if ($otherBases.Count -gt 1) {
        throw "OriginalLanguageAmbiguous: multiple audio languages were found."
    }

    return $null
}

function New-TranscriptSubtitleChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Track,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Confirmed", "Presumed")]
        [string]$Confidence
    )

    $warningCode = if ($Track.SourceKind -eq "AutomaticOriginal") {
        "AutomaticOriginalAccuracy"
    }
    elseif ($Confidence -eq "Presumed") {
        "ManualLanguageUnconfirmed"
    }
    else {
        $null
    }

    return [pscustomobject]@{
        RawTrackTag = $Track.RawTrackTag
        CanonicalLanguageTag = $Track.CanonicalLanguageTag
        BaseLanguage = $Track.BaseLanguage
        SourceKind = $Track.SourceKind
        Confidence = $Confidence
        WarningCode = $warningCode
        PreferredExtension = $Track.PreferredExtension
    }
}

function Resolve-TranscriptTrackStage {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Tracks,

        [Parameter(Mandatory = $true)]
        [string]$StageDescription
    )

    if ($Tracks.Count -gt 1) {
        $tags = @($Tracks | Select-Object -ExpandProperty RawTrackTag | Sort-Object) -join ", "
        throw "OriginalSubtitleAmbiguous: multiple $StageDescription tracks match ($tags)."
    }
    if ($Tracks.Count -eq 1) {
        return $Tracks[0]
    }
    return $null
}

function Resolve-TranscriptSubtitleChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Info
    )

    $tracks = @(Get-TranscriptSubtitleTracks -Info $Info)
    $selectable = @($tracks | Where-Object SourceKind -in @("Manual", "AutomaticOriginal"))
    $manual = @($selectable | Where-Object SourceKind -eq "Manual")
    $automatic = @($selectable | Where-Object SourceKind -eq "AutomaticOriginal")

    if ($selectable.Count -eq 0) {
        if (@($tracks | Where-Object SourceKind -eq "AutomaticUntrusted").Count -gt 0) {
            throw "NoVerifiedOriginalSubtitle: only untrusted automatic caption tracks are available."
        }
        throw "NoSubtitleTracks: no eligible subtitle tracks were found."
    }

    $evidence = Get-TranscriptOriginalLanguageEvidence -Info $Info -Tracks $tracks

    if (-not $evidence) {
        if ($manual.Count -eq 1) {
            return New-TranscriptSubtitleChoice -Track $manual[0] -Confidence "Presumed"
        }
        if ($manual.Count -gt 1) {
            throw "OriginalSubtitleAmbiguous: multiple manual tracks exist without original-language evidence."
        }
        if (@($tracks | Where-Object SourceKind -eq "AutomaticUntrusted").Count -gt 0) {
            throw "NoVerifiedOriginalSubtitle: only untrusted automatic caption tracks are available."
        }
        throw "NoSubtitleTracks: no eligible subtitle tracks were found."
    }

    foreach ($sourceTracks in @($manual, $automatic)) {
        $exact = Resolve-TranscriptTrackStage `
            -Tracks @($sourceTracks | Where-Object CanonicalLanguageTag -eq $evidence.CanonicalLanguageTag) `
            -StageDescription "exact-language"
        if ($exact) {
            return New-TranscriptSubtitleChoice -Track $exact -Confidence "Confirmed"
        }

        $sameBase = Resolve-TranscriptTrackStage `
            -Tracks @($sourceTracks | Where-Object BaseLanguage -eq $evidence.BaseLanguage) `
            -StageDescription "same-base"
        if ($sameBase) {
            return New-TranscriptSubtitleChoice -Track $sameBase -Confidence "Confirmed"
        }
    }

    throw "NoVerifiedOriginalSubtitle: no eligible subtitle track matches the original language."
}

function New-SafeFilePart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $safe = $Value
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, "-")
    }

    $safe = $safe -replace '[\s_]+', '-'
    $safe = $safe -replace '-{2,}', '-'
    $safe = $safe.Trim(" ", "-", ".")

    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80).Trim(" ", "-", ".")
    }

    if (-not $safe) {
        return "video"
    }

    return $safe
}

function New-TranscriptFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$VideoId,

        [Parameter(Mandatory = $true)]
        [string]$Language,

        [datetime]$Date = (Get-Date)
    )

    $datePart = $Date.ToString("yyyy-MM-dd")
    $titlePart = New-SafeFilePart -Value $Title
    $idPart = New-SafeFilePart -Value $VideoId
    $languagePart = New-SafeFilePart -Value $Language
    return "${datePart}_${titlePart}_${idPart}_${languagePart}.txt"
}

function Test-SubtitleTimestamp {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    return [bool]($Line -match '^\s*(?:\d{2,}:)?\d{2}:\d{2}[\.,]\d{3}\s+-->\s+(?:\d{2,}:)?\d{2}:\d{2}[\.,]\d{3}(?:\s+.*)?$')
}

function Format-TranscriptParagraphs {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Sentences
    )

    if ($Sentences.Count -eq 0) {
        return ""
    }

    $paragraphs = New-Object System.Collections.Generic.List[string]
    $current = ""
    $count = 0

    foreach ($sentence in $Sentences) {
        $sentence = $sentence.Trim()

        if (-not $current) {
            $current = $sentence
            $count = 1
            continue
        }

        if (($current.Length + $sentence.Length) -gt 520 -or $count -ge 4) {
            $paragraphs.Add($current)
            $current = $sentence
            $count = 1
        }
        else {
            $current = "$current $sentence"
            $count++
        }
    }

    if ($current) {
        $paragraphs.Add($current)
    }

    return ($paragraphs -join "`r`n`r`n")
}

function ConvertFrom-TranscriptUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-TranscriptNormalizationTerms {
    return @{
        KiraMuratova = ConvertFrom-TranscriptUtf8Bytes @(208,154,208,184,209,128,208,176,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,176)
        KireMuratovoy = ConvertFrom-TranscriptUtf8Bytes @(208,154,208,184,209,128,208,181,32,208,156,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        KirMuratovoyBad = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,184,209,128,208,188,209,131,209,128,208,176,209,130,208,190,208,178,208,190,208,185)
        Kir = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,184,209,128)
        Murat = ConvertFrom-TranscriptUtf8Bytes @(208,188,209,131,209,128,208,176,209,130)
        MuratovoySuffix = ConvertFrom-TranscriptUtf8Bytes @(208,190,208,178,208,190,208,185)
        Redimag = ConvertFrom-TranscriptUtf8Bytes @(209,128,208,181,208,180,208,184,208,188,208,176,208,179)
        FigmaStem = ConvertFrom-TranscriptUtf8Bytes @(209,132,208,184,208,179,208,188)
        EdWood = ConvertFrom-TranscriptUtf8Bytes @(208,173,208,180,32,208,146,209,131,208,180)
        EdwoodBad = ConvertFrom-TranscriptUtf8Bytes @(209,141,208,180,208,178,209,131,208,180)
        Karvaya = ConvertFrom-TranscriptUtf8Bytes @(208,186,208,176,209,128,208,178,208,176,209,143)
        WongKarWai = ConvertFrom-TranscriptUtf8Bytes @(208,146,208,190,208,189,208,179,32,208,154,208,176,209,128,45,208,178,208,176,208,185)
        FillerE = ConvertFrom-TranscriptUtf8Bytes @(209,141)
        FillerA = ConvertFrom-TranscriptUtf8Bytes @(208,176)
        FillerM = ConvertFrom-TranscriptUtf8Bytes @(208,188)
    }
}

function Normalize-TranscriptLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $terms = Get-TranscriptNormalizationTerms
    $line = $Line
    $fillers = @(
        [regex]::Escape($terms.FillerE),
        [regex]::Escape($terms.FillerA),
        [regex]::Escape($terms.FillerM),
        "uh",
        "um"
    ) -join "|"

    $line = $line -replace "(?i)^\s*($fillers)+\s+", ""

    $kir = [regex]::Escape($terms.Kir)
    $murat = [regex]::Escape($terms.Murat)
    $muratovoySuffix = [regex]::Escape($terms.MuratovoySuffix)
    $kirMuratovoyBad = [regex]::Escape($terms.KirMuratovoyBad)
    $line = $line -replace "(?i)\b$kirMuratovoyBad\b", $terms.KireMuratovoy
    $line = $line -replace "(?i)\b($kir\s*$murat\w*|$kir$murat\w*)$muratovoySuffix\b", $terms.KireMuratovoy
    $line = $line -replace "(?i)\b($kir\s*$murat\w*|$kir$murat\w*)\b", $terms.KiraMuratova

    $redimag = [regex]::Escape($terms.Redimag)
    $line = $line -replace "(?i)\b(readymag|ready\s*mag|redimag\w*|$redimag\w*)\b", "Readymag"

    $figmaStem = [regex]::Escape($terms.FigmaStem)
    $line = $line -replace "(?i)\b(figma|figm\w*|$figmaStem\w*)\b", "Figma"

    $line = $line -replace "(?i)\b(webp|web\s*p|webpay|vp)\b", "WebP"
    $line = $line -replace "(?i)\b(gif|gi|gv)\b", "GIF"

    $edwoodBad = [regex]::Escape($terms.EdwoodBad)
    $line = $line -replace "(?i)\b(ed\s*wood|edwood|$edwoodBad)\b", $terms.EdWood

    $karvaya = [regex]::Escape($terms.Karvaya)
    $line = $line -replace "(?i)\b(wong\s*kar\s*wai|karvaya|$karvaya)\b", $terms.WongKarWai

    $line = $line -replace '\s{2,}', ' '
    return $line.Trim()
}

function Format-CleanTranscriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sentences = [regex]::Split($Text.Trim(), '(?<=[.!?])\s+') |
        Where-Object { $_.Trim() }
    $paragraphs = New-Object System.Collections.Generic.List[string]
    $current = ""
    $sentenceCount = 0

    foreach ($sentence in $sentences) {
        $sentence = $sentence.Trim()

        if (-not $current) {
            $current = $sentence
            $sentenceCount = 1
            continue
        }

        if (($current.Length + $sentence.Length) -gt 520 -or $sentenceCount -ge 3) {
            $paragraphs.Add($current)
            $current = $sentence
            $sentenceCount = 1
        }
        else {
            $current = "$current $sentence"
            $sentenceCount++
        }
    }

    if ($current) {
        $paragraphs.Add($current)
    }

    return ($paragraphs -join "`r`n`r`n")
}

function Get-TranscriptReviewText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CleanPath
    )

    $terms = Get-TranscriptNormalizationTerms
    $lines = @(
        "Review checklist",
        "",
        "Clean transcript: $CleanPath",
        "",
        "Check names and terms manually:",
        "- $($terms.KiraMuratova)",
        "- Readymag",
        "- Figma",
        "- WebP",
        "- GIF",
        "- $($terms.EdWood)",
        "- $($terms.WongKarWai)",
        "",
        "This file is a deterministic cleanup aid, not a verified transcript."
    )

    return (($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine)
}

function Convert-SubtitleFileToTranscriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$TranscriptMode
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Subtitle file was not found: $Path"
    }

    $sourceLines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    $lines = New-Object System.Collections.Generic.List[string]
    $prev = $null
    $block = $null
    $atCueBoundary = $true
    $inDocumentHeader = $true

    for ($i = 0; $i -lt $sourceLines.Count; $i++) {
        $rawLine = [string]$sourceLines[$i]

        if ($block) {
            if ([string]::IsNullOrWhiteSpace($rawLine)) {
                $block = $null
                $atCueBoundary = $true
            }

            continue
        }

        if ([string]::IsNullOrWhiteSpace($rawLine)) {
            $atCueBoundary = $true
            continue
        }

        if ($inDocumentHeader -and $rawLine -match '^\s*(?:WEBVTT(?:\s.*)?|Kind:.*|Language:.*)\s*$') {
            continue
        }

        $inDocumentHeader = $false

        if ($atCueBoundary -and $rawLine -match '^\s*(NOTE|STYLE|REGION)(?:\s|$)') {
            $block = $Matches[1]
            continue
        }

        if ($atCueBoundary) {
            $nextIndex = $i + 1
            while ($nextIndex -lt $sourceLines.Count -and [string]::IsNullOrWhiteSpace([string]$sourceLines[$nextIndex])) {
                $nextIndex++
            }

            if ($nextIndex -lt $sourceLines.Count -and (Test-SubtitleTimestamp -Line ([string]$sourceLines[$nextIndex]))) {
                continue
            }
        }

        if (Test-SubtitleTimestamp -Line $rawLine) {
            $atCueBoundary = $false
            continue
        }

        $line = $rawLine -replace '<[^>]+>', ''
        $line = [System.Net.WebUtility]::HtmlDecode($line)
        $line = $line -replace '>>', ''
        $line = $line -replace ([char]0x00A0), ' '
        $line = $line -replace '\[.*?\]', ''
        $line = $line.Trim()

        if ($TranscriptMode) {
            $line = Normalize-TranscriptLine -Line $line
        }

        if ($line -and $line -ne $prev) {
            $prev = $line
            $lines.Add($line)
        }

        $atCueBoundary = $false
    }

    $text = ($lines -join ' ')
    $text = $text -replace '\s{2,}', ' '
    $text = $text -replace '\s+([.,!?;:])', '$1'
    $text = $text -replace '([(\[{])\s+', '$1'
    $text = $text -replace '\s+([)\]}])', '$1'
    $text = $text.Trim()

    if (-not $text) {
        throw "Subtitle file did not contain readable transcript text."
    }

    if ($TranscriptMode) {
        return Format-CleanTranscriptText -Text $text
    }

    $sentences = @([regex]::Split($text, '(?<=[.!?])\s+') | Where-Object { $_.Trim() })
    return Format-TranscriptParagraphs -Sentences $sentences
}

function New-TranscriptOperationId {
    param([string]$OperationId)

    if (-not $OperationId) {
        return [Guid]::NewGuid().ToString("N")
    }

    if ($OperationId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "Transcript operation id must be a 32-character GUID."
    }

    return $OperationId.ToLowerInvariant()
}

function Get-TranscriptOperationStagingRoot {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    Join-Path $OutputDir (".youtube-transcript-operation-" + $OperationId)
}

function Remove-TranscriptPublicationArtifacts {
    param([Parameter(Mandatory = $true)][string]$PublicationDirectory)

    if (-not (Test-Path -LiteralPath $PublicationDirectory)) {
        return
    }

    $commitPath = Join-Path $PublicationDirectory "commit.marker"
    $manifestPath = Join-Path $PublicationDirectory "manifest.json"
    if (-not (Test-Path -LiteralPath $commitPath) -and (Test-Path -LiteralPath $manifestPath)) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($entry in @($manifest.Entries)) {
            if ($entry.TargetPath -and $entry.Identity) {
                [void][TranscriptFileCleanupTools]::DeleteIfIdentityMatches(
                    [string]$entry.TargetPath,
                    [string]$entry.Identity
                )
            }
        }
    }

    Remove-Item -LiteralPath $PublicationDirectory -Recurse -Force -ErrorAction Stop
}

function Remove-TranscriptOperationStagingRoot {
    param([Parameter(Mandatory = $true)][string]$StagingRoot)

    if (-not (Test-Path -LiteralPath $StagingRoot)) {
        return
    }

    foreach ($publication in @(Get-ChildItem -LiteralPath $StagingRoot -Directory -Filter "publication-*" -ErrorAction Stop)) {
        Remove-TranscriptPublicationArtifacts -PublicationDirectory $publication.FullName
    }
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force -ErrorAction Stop
}

function Close-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)][object]$Reservation,
        [bool]$DeleteFiles
    )

    $cleanupError = $null
    try {
        if ($Reservation.StageDirectory -and (Test-Path -LiteralPath $Reservation.StageDirectory)) {
            Remove-TranscriptPublicationArtifacts -PublicationDirectory $Reservation.StageDirectory
        }
    }
    catch {
        $cleanupError = $_
    }
    finally {
        if ($Reservation.LockStream) {
            try { $Reservation.LockStream.Dispose() }
            catch { if (-not $cleanupError) { $cleanupError = $_ } }
        }
    }

    if ($cleanupError) { throw $cleanupError }
}

function New-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [string]$Stem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ArtifactSuffixes,

        [Parameter(Mandatory = $true)]
        [string]$OperationId
    )

    $suffixes = @($ArtifactSuffixes | Select-Object -Unique)
    $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $OperationId
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    for ($index = 1; $true; $index++) {
        $candidateName = if ($index -eq 1) { $Stem } else { "$Stem-$index" }
        $candidateStem = Join-Path $OutputDir $candidateName
        $lockName = ".youtube-transcript-lock-{0}.tmp" -f (New-SafeFilePart -Value $candidateName)
        $lockPath = Join-Path $OutputDir $lockName
        $lockStream = $null

        try {
            $lockStream = [TranscriptFileCleanupTools]::OpenDeleteOnCloseLock($lockPath)
        }
        catch [System.IO.IOException] {
            $nativeError = $_.Exception.HResult -band 0xFFFF
            if ($nativeError -in 80, 183) { continue }
            throw
        }

        $collision = @($suffixes | Where-Object { Test-Path -LiteralPath "$candidateStem$_" }).Count -gt 0
        if ($collision) {
            $lockStream.Dispose()
            continue
        }

        $stageDirectory = Join-Path $stagingRoot ("publication-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $stageDirectory -ErrorAction Stop | Out-Null
        $entries = New-Object System.Collections.Generic.List[object]
        $entryIndex = 0
        foreach ($suffix in $suffixes) {
            $entries.Add([pscustomobject]@{
                    Suffix = [string]$suffix
                    TargetPath = "$candidateStem$suffix"
                    StagePath = Join-Path $stageDirectory ("artifact-{0:D2}.stage" -f $entryIndex)
                })
            $entryIndex++
        }
        return [pscustomobject]@{
            StemPath = $candidateStem
            Entries = $entries.ToArray()
            LockStream = $lockStream
            StageDirectory = $stageDirectory
            ManifestPath = Join-Path $stageDirectory "manifest.json"
            CommitPath = Join-Path $stageDirectory "commit.marker"
        }
    }
}

function Get-TranscriptReservationEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $entry = $Reservation.Entries |
        Where-Object { [string]$_.Suffix -eq $Suffix } |
        Select-Object -First 1
    if (-not $entry) {
        throw "The output reservation does not contain suffix '$Suffix'."
    }

    return $entry
}

function Write-TranscriptReservationText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $entry = Get-TranscriptReservationEntry -Reservation $Reservation -Suffix $Suffix
    [System.IO.File]::WriteAllText(
        [string]$entry.StagePath,
        $Text,
        (New-Object System.Text.UTF8Encoding($true))
    )
}

function Copy-TranscriptFileToReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $entry = Get-TranscriptReservationEntry -Reservation $Reservation -Suffix $Suffix
    [System.IO.File]::Copy($Path, [string]$entry.StagePath, $false)
}

function Publish-TranscriptOutputReservation {
    param(
        [Parameter(Mandatory = $true)][object]$Reservation,
        [scriptblock]$OnArtifactPublished
    )

    $manifestEntries = @(
        foreach ($entry in @($Reservation.Entries)) {
            if (-not (Test-Path -LiteralPath $entry.StagePath)) {
                throw "Transcript staging artifact is missing: $($entry.StagePath)"
            }
            [pscustomobject]@{
                TargetPath = [string]$entry.TargetPath
                Identity = [TranscriptFileCleanupTools]::GetIdentity([string]$entry.StagePath)
            }
        }
    )
    $manifestTemp = "$($Reservation.ManifestPath).tmp"
    [System.IO.File]::WriteAllText(
        $manifestTemp,
        ([pscustomobject]@{ Version = 1; Entries = $manifestEntries } | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($true))
    )
    [System.IO.File]::Move($manifestTemp, [string]$Reservation.ManifestPath)

    $publishedCount = 0
    foreach ($entry in @($Reservation.Entries)) {
        [System.IO.File]::Move([string]$entry.StagePath, [string]$entry.TargetPath)
        $publishedCount++
        if ($OnArtifactPublished) {
            & $OnArtifactPublished $publishedCount $entry | Out-Null
        }
    }
    [System.IO.File]::WriteAllText([string]$Reservation.CommitPath, "committed")
}

function Save-TranscriptFromSubtitleFileAtReservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Reservation,

        [bool]$CleanTranscript
    )

    $textSuffix = if ($CleanTranscript) {
        ".clean.txt"
    }
    else {
        ".txt"
    }

    $textPath = "$($Reservation.StemPath)$textSuffix"
    $text = Convert-SubtitleFileToTranscriptText -Path $Path -TranscriptMode:$CleanTranscript
    Write-TranscriptReservationText `
        -Reservation $Reservation `
        -Suffix $textSuffix `
        -Text ($text + [System.Environment]::NewLine)

    $reviewPath = $null
    if ($CleanTranscript) {
        $reviewPath = "$($Reservation.StemPath).review.txt"
        Write-TranscriptReservationText `
            -Reservation $Reservation `
            -Suffix ".review.txt" `
            -Text (Get-TranscriptReviewText -CleanPath $textPath)
    }

    return [pscustomobject]@{
        TextPath = $textPath
        ReviewPath = $reviewPath
    }
}

function Save-TranscriptFromSubtitleFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$CleanTranscript,

        [string]$OperationId
    )

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $operation = New-TranscriptOperationId -OperationId $OperationId
    $sourceStem = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path))
    $artifactSuffixes = if ($CleanTranscript) {
        @(".clean.txt", ".review.txt")
    }
    else {
        @(".txt")
    }
    $reservation = New-TranscriptOutputReservation `
        -OutputDir $OutputDir `
        -Stem $sourceStem `
        -ArtifactSuffixes $artifactSuffixes `
        -OperationId $operation

    $succeeded = $false
    try {
        $result = Save-TranscriptFromSubtitleFileAtReservation `
            -Path $Path `
            -Reservation $reservation `
            -CleanTranscript $CleanTranscript
        Publish-TranscriptOutputReservation -Reservation $reservation
        $succeeded = $true
        return $result
    }
    finally {
        Close-TranscriptOutputReservation `
            -Reservation $reservation `
            -DeleteFiles (-not $succeeded)
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
    }
}

function Get-BoundedTranscriptDiagnostic {
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $diagnostic = $Text.Trim()
    if ($diagnostic.Length -le $MaximumLength) {
        return $diagnostic
    }

    return $diagnostic.Substring($diagnostic.Length - $MaximumLength)
}

function New-TranscriptSubtitleDownloadArguments {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Choice,

        [Parameter(Mandatory = $true)]
        [string]$OutputTemplate,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [switch]$Srt
    )

    $sourceFlag = switch ($Choice.SourceKind) {
        "Manual" { "--write-subs" }
        "AutomaticOriginal" { "--write-auto-subs" }
        default { throw "UnsupportedYtDlpContract: unsupported selected subtitle source '$($Choice.SourceKind)'." }
    }

    $arguments = @(
        "--skip-download",
        "--no-playlist",
        "--extractor-args", "youtube:skip=translated_subs",
        "--sub-langs", [string]$Choice.RawTrackTag,
        "--sub-format", "vtt/srt",
        $sourceFlag
    )
    if ($Srt) {
        $arguments += @("--convert-subs", "srt")
    }
    $arguments += @("-o", $OutputTemplate, $Url)

    return @(Get-ManagedYtDlpArguments -ArgumentList $arguments)
}

function ConvertTo-CanonicalSubtitleStem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stem,

        [Parameter(Mandatory = $true)]
        [object]$Choice
    )

    $rawSuffix = "." + [string]$Choice.RawTrackTag
    if ($Stem.EndsWith($rawSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Stem.Substring(0, $Stem.Length - $rawSuffix.Length) + "." + [string]$Choice.CanonicalLanguageTag
    }

    return $Stem + "." + [string]$Choice.CanonicalLanguageTag
}

function Save-TranscriptFromYoutubeCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$NoClean,

        [bool]$KeepSubtitles,

        [bool]$Srt,

        [bool]$CleanTranscript,

        [string]$YtDlpPath,

        [string]$OperationId
    )

    $tool = Get-YtDlpPath -PreferredPath $YtDlpPath
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $operation = New-TranscriptOperationId -OperationId $OperationId
    $info = Invoke-YtDlpJson -YtDlpPath $tool -Url $Url
    $choice = Resolve-TranscriptSubtitleChoice -Info $info

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-cli-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $downloadedSubtitles = @()
    $lastExitCode = 0
    $lastOutput = ""
    $lastStdErr = ""

    try {
        $arguments = New-TranscriptSubtitleDownloadArguments `
            -Choice $choice `
            -OutputTemplate (Join-Path $tempDir "%(title)s [%(id)s].%(ext)s") `
            -Url $Url `
            -Srt:$Srt
        $downloadResult = Invoke-TranscriptProcess `
            -FilePath $tool `
            -ArgumentList $arguments `
            -WorkingDirectory $tempDir
        $lastExitCode = $downloadResult.ExitCode
        $lastOutput = Get-BoundedTranscriptDiagnostic -Text ([string]$downloadResult.Output)
        $lastStdErr = Get-BoundedTranscriptDiagnostic -Text ([string]$downloadResult.StdErr)
        $downloadedSubtitles = @(Get-ChildItem -LiteralPath $tempDir -File |
            Where-Object { $_.Extension -in ".vtt", ".srt" })

        if ($downloadedSubtitles.Count -eq 0) {
            return [pscustomobject]@{
                TextPath = $null
                ReviewPath = $null
                SubtitlePaths = @()
                OutputDir = $OutputDir
                FoundSubtitles = $false
                ExitCode = if ($NoClean) { $lastExitCode } else { 1 }
                YtDlpExitCode = $lastExitCode
                Output = $lastOutput
                StdErr = $lastStdErr
                RawTrackTag = $choice.RawTrackTag
                CanonicalLanguageTag = $choice.CanonicalLanguageTag
                BaseLanguage = $choice.BaseLanguage
                SourceKind = $choice.SourceKind
                Confidence = $choice.Confidence
                WarningCode = $choice.WarningCode
            }
        }

        if ($NoClean) {
            $subtitlePaths = New-Object System.Collections.Generic.List[string]
            $subtitleGroups = $downloadedSubtitles |
                Group-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
            foreach ($subtitleGroup in $subtitleGroups) {
                $relatedSubtitles = @($subtitleGroup.Group)
                $relatedSuffixes = @($relatedSubtitles |
                    ForEach-Object { $_.Extension } |
                    Select-Object -Unique)
                $reservation = New-TranscriptOutputReservation `
                    -OutputDir $OutputDir `
                    -Stem (ConvertTo-CanonicalSubtitleStem -Stem ([string]$subtitleGroup.Name) -Choice $choice) `
                    -ArtifactSuffixes $relatedSuffixes `
                    -OperationId $operation
                $groupSucceeded = $false
                try {
                    foreach ($subtitle in $relatedSubtitles) {
                        Copy-TranscriptFileToReservation `
                            -Path $subtitle.FullName `
                            -Reservation $reservation `
                            -Suffix $subtitle.Extension
                        $subtitlePaths.Add("$($reservation.StemPath)$($subtitle.Extension)")
                    }
                    Publish-TranscriptOutputReservation -Reservation $reservation
                    $groupSucceeded = $true
                }
                finally {
                    Close-TranscriptOutputReservation `
                        -Reservation $reservation `
                        -DeleteFiles (-not $groupSucceeded)
                }
            }

            return [pscustomobject]@{
                TextPath = $null
                ReviewPath = $null
                SubtitlePaths = $subtitlePaths.ToArray()
                OutputDir = $OutputDir
                FoundSubtitles = $true
                ExitCode = 0
                YtDlpExitCode = $lastExitCode
                Output = $lastOutput
                StdErr = $lastStdErr
                RawTrackTag = $choice.RawTrackTag
                CanonicalLanguageTag = $choice.CanonicalLanguageTag
                BaseLanguage = $choice.BaseLanguage
                SourceKind = $choice.SourceKind
                Confidence = $choice.Confidence
                WarningCode = $choice.WarningCode
            }
        }

        $selected = $downloadedSubtitles |
            Sort-Object `
                @{ Expression = { if ($Srt -and $_.Extension -eq ".srt") { 0 } elseif (-not $Srt -and $_.Extension -eq ".vtt") { 0 } else { 1 } }; Ascending = $true },
                @{ Expression = { $_.FullName }; Ascending = $true } |
            Select-Object -First 1
        $selectedStem = ConvertTo-CanonicalSubtitleStem `
            -Stem ([System.IO.Path]::GetFileNameWithoutExtension($selected.Name)) `
            -Choice $choice
        $artifactSuffixes = @(
            if ($CleanTranscript) {
                ".clean.txt"
                ".review.txt"
            }
            else {
                ".txt"
            }
        )
        if ($KeepSubtitles) {
            $artifactSuffixes += $selected.Extension
        }

        $reservation = New-TranscriptOutputReservation `
            -OutputDir $OutputDir `
            -Stem $selectedStem `
            -ArtifactSuffixes $artifactSuffixes `
            -OperationId $operation
        $reservationSucceeded = $false
        try {
            $saved = Save-TranscriptFromSubtitleFileAtReservation `
                -Path $selected.FullName `
                -Reservation $reservation `
                -CleanTranscript $CleanTranscript
            $subtitlePaths = @()

            if ($KeepSubtitles) {
                $destination = "$($reservation.StemPath)$($selected.Extension)"
                Copy-TranscriptFileToReservation `
                    -Path $selected.FullName `
                    -Reservation $reservation `
                    -Suffix $selected.Extension
                $subtitlePaths = @($destination)
            }
            Publish-TranscriptOutputReservation -Reservation $reservation
            $reservationSucceeded = $true
        }
        finally {
            Close-TranscriptOutputReservation `
                -Reservation $reservation `
                -DeleteFiles (-not $reservationSucceeded)
        }

        return [pscustomobject]@{
            TextPath = $saved.TextPath
            ReviewPath = $saved.ReviewPath
            SubtitlePaths = $subtitlePaths
            OutputDir = $OutputDir
            FoundSubtitles = $true
            ExitCode = 0
            YtDlpExitCode = $lastExitCode
            Output = $lastOutput
            StdErr = $lastStdErr
            RawTrackTag = $choice.RawTrackTag
            CanonicalLanguageTag = $choice.CanonicalLanguageTag
            BaseLanguage = $choice.BaseLanguage
            SourceKind = $choice.SourceKind
            Confidence = $choice.Confidence
            WarningCode = $choice.WarningCode
        }
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
    }
}

function Save-TranscriptFromYoutube {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [bool]$KeepSubtitles,

        [string]$YtDlpPath,

        [scriptblock]$OnStatus,

        [string]$OperationId
    )

    if (-not (Test-YoutubeUrl -Url $Url)) {
        throw "The link does not look like a YouTube video URL."
    }

    $tool = Get-YtDlpPath -PreferredPath $YtDlpPath
    $operation = New-TranscriptOperationId -OperationId $OperationId

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        try {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }
        catch {
            throw "Cannot create or access the selected output folder: $OutputDir"
        }
    }

    try {
        $probe = Join-Path $OutputDir (".write-test-" + [System.Guid]::NewGuid().ToString("N"))
        Set-Content -LiteralPath $probe -Value "test" -Encoding ascii
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        throw "Cannot write files to the selected output folder: $OutputDir"
    }

    if ($OnStatus) { & $OnStatus "Checking link" }
    $info = Invoke-YtDlpJson -YtDlpPath $tool -Url $Url

    if ($OnStatus) { & $OnStatus "Looking for subtitles" }
    $choice = Resolve-TranscriptSubtitleChoice -Info $info

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("youtube-transcript-tool-" + $operation)
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $args = New-TranscriptSubtitleDownloadArguments `
            -Choice $choice `
            -OutputTemplate (Join-Path $tempDir "%(id)s.%(ext)s") `
            -Url $Url

        if ($OnStatus) { & $OnStatus "Saving file" }
        $downloadResult = Invoke-TranscriptProcess -FilePath $tool -ArgumentList $args
        $downloadOutput = $downloadResult.Output
        $exitCode = $downloadResult.ExitCode
        $subtitleFile = Get-ChildItem -LiteralPath $tempDir -File |
            Where-Object { $_.Extension -in ".vtt", ".srt" } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($exitCode -ne 0 -and -not $subtitleFile) {
            $fullMessage = ([string]$downloadOutput).Trim()
            $message = Get-BoundedTranscriptDiagnostic -Text $fullMessage

            if ($fullMessage -match "HTTP Error 429|Too Many Requests|rate.?limit") {
                throw "YouTube temporarily rate-limited subtitle downloads. Wait a little and try again."
            }

            throw "Could not download subtitles. yt-dlp said: $message"
        }

        if (-not $subtitleFile) {
            throw "yt-dlp did not produce a subtitle file for the selected original track."
        }

        $videoTitle = if ($info.title) { [string]$info.title } else { "video" }
        $videoId = if ($info.id) { [string]$info.id } else { [System.Guid]::NewGuid().ToString("N") }
        $fileName = New-TranscriptFileName -Title $videoTitle -VideoId $videoId -Language $choice.CanonicalLanguageTag
        $outputStemName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $artifactSuffixes = @(".txt")
        if ($KeepSubtitles) {
            $artifactSuffixes += $subtitleFile.Extension
        }

        $reservation = New-TranscriptOutputReservation `
            -OutputDir $OutputDir `
            -Stem $outputStemName `
            -ArtifactSuffixes $artifactSuffixes `
            -OperationId $operation
        $reservationSucceeded = $false
        try {
            $txtPath = "$($reservation.StemPath).txt"
            $text = Convert-SubtitleFileToTranscriptText -Path $subtitleFile.FullName
            Write-TranscriptReservationText `
                -Reservation $reservation `
                -Suffix ".txt" `
                -Text ($text + [System.Environment]::NewLine)

            $subtitlePath = $null
            if ($KeepSubtitles) {
                $subtitlePath = "$($reservation.StemPath)$($subtitleFile.Extension)"
                Copy-TranscriptFileToReservation `
                    -Path $subtitleFile.FullName `
                    -Reservation $reservation `
                    -Suffix $subtitleFile.Extension
            }
            Publish-TranscriptOutputReservation -Reservation $reservation
            $reservationSucceeded = $true
        }
        finally {
            Close-TranscriptOutputReservation `
                -Reservation $reservation `
                -DeleteFiles (-not $reservationSucceeded)
        }

        if ($OnStatus) { & $OnStatus "Done" }

        return [pscustomobject]@{
            TextPath = $txtPath
            SubtitlePath = $subtitlePath
            OutputDir = $OutputDir
            RawTrackTag = $choice.RawTrackTag
            CanonicalLanguageTag = $choice.CanonicalLanguageTag
            BaseLanguage = $choice.BaseLanguage
            SourceKind = $choice.SourceKind
            Confidence = $choice.Confidence
            WarningCode = $choice.WarningCode
            Title = $videoTitle
            VideoId = $videoId
        }
    }
    catch {
        throw $_
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $stagingRoot = Get-TranscriptOperationStagingRoot -OutputDir $OutputDir -OperationId $operation
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-TranscriptOperationStagingRoot -StagingRoot $stagingRoot
        }
    }
}

Export-ModuleMember -Function @(
    "Read-TranscriptSettings",
    "Write-TranscriptSettings",
    "Get-YtDlpPath",
    "Test-YoutubeUrl",
    "Invoke-TranscriptProcess",
    "Invoke-TranscriptWorkerProcess",
    "Invoke-YtDlpJson",
    "Get-TranscriptSubtitleInventory",
    "Get-AvailableTranscriptLanguages",
    "Resolve-TranscriptSubtitleChoice",
    "New-TranscriptFileName",
    "Convert-SubtitleFileToTranscriptText",
    "Save-TranscriptFromSubtitleFile",
    "Save-TranscriptFromYoutubeCli",
    "Save-TranscriptFromYoutube"
)
