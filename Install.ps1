#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Install','Deploy','Status','Validate')]
    [string]$Action = 'Plan',
    [string]$Config = (Join-Path $PSScriptRoot 'config.local.psd1'),
    [switch]$Approve,
    [switch]$AcceptMediaLicense,
    [switch]$AllowDependencyInstall,
    [switch]$Login,
    [switch]$Online,
    [switch]$GuestChecks,
    [securestring]$HostPassword,
    [securestring]$GuestPassword
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Lab.psm1') -Force -DisableNameChecking
try {
    $settings = Read-LabConfig $Config
    if ($Action -eq 'Plan') {
        Get-LabPlan $settings | ConvertTo-Json -Depth 8
        return
    }
    if ($Action -eq 'Validate' -and -not $Online) {
        & (Join-Path $PSScriptRoot 'tests\Test-Local.ps1')
        if (-not $?) { throw 'Local tests failed.' }
        return
    }
    if ($Action -in 'Install','Deploy') {
        if (-not $Approve) { throw 'Installation creates billable resources. Review Plan, then pass -Approve explicitly.' }
        if (-not $AcceptMediaLicense) { throw 'Read the media license first; -AcceptMediaLicense authorizes unattended Windows setup.' }
        Invoke-LabInstall -Config $settings -Root $PSScriptRoot -AllowDependencyInstall:$AllowDependencyInstall -Login:$Login -HostPassword $HostPassword -GuestPassword $GuestPassword
        return
    }
    if ($Login -or $AllowDependencyInstall) { throw 'Status/online Validate never install dependencies or log in. Authenticate explicitly outside these actions.' }
    if ($GuestChecks -and -not $Approve) { throw '-GuestChecks executes a read-only probe through Azure Run Command. Pass -Approve to authorize that control-plane operation.' }
    Get-LabStatus -Config $settings -Root $PSScriptRoot -GuestChecks:$GuestChecks -RequireHealthy:($Action -eq 'Validate')
}
catch {
    # Do not emit ErrorRecord/InvocationInfo: either can contain credential arguments.
    Write-Host ("FAILED: " + (Protect-LabText $_.Exception.Message)) -ForegroundColor Red
    exit 1
}
