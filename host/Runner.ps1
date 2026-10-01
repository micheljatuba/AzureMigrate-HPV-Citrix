#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Install','Status')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force -DisableNameChecking
$root = Split-Path $PSScriptRoot
if ($Action -eq 'Status') {
    Get-HVStatus -Root $root | ConvertTo-Json -Depth 12 -Compress
    return
}
try { Invoke-HVInstall -Root $root }
catch {
    # Engine writes only redacted, structured status; no transcripts or arguments.
    Write-Output 'Hyper-V lab installation stopped. Inspect state.json and events.jsonl on the owned host.'
    exit 1
}
