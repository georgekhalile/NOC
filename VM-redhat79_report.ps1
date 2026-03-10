param(
  [Parameter(Mandatory=$true)][string]$vCenter,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$true)][string]$Password,
  [Parameter(Mandatory=$true)][string]$OutCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-ParentFolder([string]$filePath) {
  if ([string]::IsNullOrWhiteSpace($filePath)) { throw "OutCsv path is empty." }

  if ($filePath.StartsWith("~")) { $filePath = $filePath -replace "^~", $HOME }

  $full = [System.IO.Path]::GetFullPath($filePath)
  $parent = [System.IO.Path]::GetDirectoryName($full)
  if ([string]::IsNullOrWhiteSpace($parent)) { throw "Could not determine parent folder for: $full" }

  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  return $full
}

function Try-GetFirstIPv4($ipList) {
  if (-not $ipList) { return "" }
  $ipv4 = $ipList | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
  if ($ipv4) { return $ipv4 }
  return ($ipList | Select-Object -First 1)
}

function Classify-Rhel79OrBelow([string]$guestOsString) {
  if ([string]::IsNullOrWhiteSpace($guestOsString)) { return "UNKNOWN" }

  $looksLike7 = $guestOsString -match '(Red Hat|RHEL|CentOS|Rocky|Alma).*7(\.\d+)?'
  if (-not $looksLike7) { return "NO" }

  if ($guestOsString -match '7\.(\d+)') {
    $minor = [int]$Matches[1]
    if ($minor -le 9) { return "YES" }
    return "NO"
  }

  return "YES"
}

try {
  $OutCsvFull = Ensure-ParentFolder $OutCsv

  if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw "VMware.PowerCLI is not installed. Install it with: Install-Module VMware.PowerCLI"
  }

  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
  Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false | Out-Null

  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($Username, $sec)

  Write-Host "Connecting to vCenter: $vCenter"
  Connect-VIServer -Server $vCenter -Credential $cred | Out-Null

  Write-Host "Collecting VMs..."
  $vms = Get-VM

  $rows = foreach ($vm in $vms) {
    $name  = $vm.Name
    $power = $vm.PowerState.ToString()

    $guestOs = ""
    try { $guestOs = $vm.Guest.OSFullName } catch { $guestOs = "" }
    if ([string]::IsNullOrWhiteSpace($guestOs)) {
      try { $guestOs = $vm.ExtensionData.Summary.Config.GuestFullName } catch { $guestOs = "" }
    }

    $tools = ""
    try { $tools = $vm.ExtensionData.Guest.ToolsStatus.ToString() } catch { $tools = "" }

    $ip = ""
    try { $ip = Try-GetFirstIPv4 $vm.Guest.IPAddress } catch { $ip = "" }

    $flag = Classify-Rhel79OrBelow $guestOs

    [PSCustomObject]@{
      vm_name           = $name
      ip                = $ip
      power_state       = $power
      guest_os          = $guestOs
      tools_status      = $tools
      rhel_7_9_or_below = $flag
    }
  }

  Write-Host ("Rows collected: {0}" -f ($rows.Count))
  Write-Host "Writing CSV to: $OutCsvFull"

  $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsvFull -Force

  if (-not (Test-Path -LiteralPath $OutCsvFull)) {
    throw "Export finished but file not found at: $OutCsvFull"
  }

  Write-Host "SUCCESS. Report created:"
  Write-Host $OutCsvFull
}
catch {
  Write-Error ("FAILED: {0}" -f $_.Exception.Message)
  exit 1
}
finally {
  try {
    if (Get-VIServer -ErrorAction SilentlyContinue) {
      Disconnect-VIServer -Server $vCenter -Confirm:$false | Out-Null
      Write-Host "Disconnected from vCenter."
    }
  } catch {}
}
