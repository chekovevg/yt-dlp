param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("0", "1")]
    [string]$KeepSubtitles,

    [Parameter(Mandatory = $true)]
    [string]$OperationId
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Write-TranscriptWorkerMessage {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Status", "Result", "Error")]
        [string]$Kind,

        [AllowNull()]
        [object]$Value
    )

    $json = [pscustomobject]@{
        Kind = $Kind
        Value = $Value
    } | ConvertTo-Json -Depth 8 -Compress

    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    [Console]::Out.WriteLine("TT1:" + $payload)
    [Console]::Out.Flush()
}

try {
    $root = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $root "transcript-tool.psm1") -Force

    Save-TranscriptFromYoutube `
        -Url $Url `
        -OutputDir $OutputDir `
        -KeepSubtitles:($KeepSubtitles -eq "1") `
        -OperationId $OperationId `
        -OnStatus {
            param($status)
            [pscustomobject]@{
                Kind = "Status"
                Value = $status
            }
        } |
        ForEach-Object {
            if ([string]$_.Kind -eq "Status") {
                Write-TranscriptWorkerMessage -Kind "Status" -Value $_.Value
            }
            else {
                Write-TranscriptWorkerMessage -Kind "Result" -Value $_
            }
        }
}
catch {
    Write-TranscriptWorkerMessage -Kind "Error" -Value $_.Exception.Message
    exit 1
}
