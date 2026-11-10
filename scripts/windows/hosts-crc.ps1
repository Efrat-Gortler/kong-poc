# Points the OpenShift Local / POC host names at the GCP VM (Windows hosts file).
# Run through hosts-crc.cmd (it asks for administrator rights). Re-run when the VM IP changes:
# the previous kong-poc block is replaced, the rest of the hosts file is untouched.
param([Parameter(Mandatory = $true)][string]$Ip)
$ErrorActionPreference = 'Stop'
if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "not an IPv4 address: $Ip" }
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$names = @(
  'api.crc.testing',
  'console-openshift-console.apps-crc.testing',
  'oauth-openshift.apps-crc.testing',
  'downloads-openshift-console.apps-crc.testing',
  'canary-openshift-ingress-canary.apps-crc.testing',
  'default-route-openshift-image-registry.apps-crc.testing',
  'gslb-gslb-sim.apps-crc.testing',
  'gslb-control-gslb-sim.apps-crc.testing',
  'keycloak-idp.apps-crc.testing',
  'blocking-blocking.apps-crc.testing',
  'openshift-gitops-server-openshift-gitops.apps-crc.testing'
)
$begin = '# >>> kong-poc (GCP OpenShift Local) >>>'
$end   = '# <<< kong-poc <<<'
Copy-Item $hostsFile "$hostsFile.kong-poc.bak" -Force
$lines = Get-Content $hostsFile
$out = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($l in $lines) {
  if ($l -eq $begin) { $skip = $true; continue }
  if ($l -eq $end) { $skip = $false; continue }
  if (-not $skip) { $out.Add($l) }
}
$out.Add($begin)
foreach ($n in $names) { $out.Add("$Ip`t$n") }
$out.Add($end)
Set-Content -Path $hostsFile -Value $out -Encoding ASCII
ipconfig /flushdns | Out-Null
Write-Host "hosts updated: $($names.Count) names -> $Ip (backup: hosts.kong-poc.bak)"
Write-Host "Console: https://console-openshift-console.apps-crc.testing"
