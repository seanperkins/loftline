# The Windows check of scripts/check-samples.sh: posts every sample with every built-in post and compares each program, byte for byte,
# with the one the Mac committed. It never rewrites samples/expected: a difference is a bug or a line in docs/PLATFORMS.md.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
swift build --product loftline-cli
if ($LASTEXITCODE -ne 0) { exit 1 }
$bin = (swift build --show-bin-path).Trim()
$cli = Join-Path $bin "loftline-cli.exe"
$work = Join-Path ([IO.Path]::GetTempPath()) ("loftline-samples-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$failed = $false
$count = 0
$ids = & $cli posts --builtin-only | ForEach-Object { ($_ -split "`t")[0] }
foreach ($id in $ids) {
  foreach ($sample in Get-ChildItem samples -Filter *.loftline) {
    $name = $sample.BaseName
    $want = Get-ChildItem (Join-Path "samples/expected" $id) -Filter "$name.*" | Select-Object -First 1
    if (-not $want) { Write-Error "FAIL: no committed program for $id/$name" -ErrorAction Continue; $failed = $true; continue }
    $out = Join-Path $work $id
    & $cli export $sample.FullName --post $id --builtin-only --quiet --out $out
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: $id/$name did not post"; $failed = $true; continue }
    $got = Join-Path $out $want.Name
    if (-not (Test-Path $got)) { Write-Host "FAIL: $id/$name wrote no $($want.Name)"; $failed = $true; continue }
    $count++
    if ((Get-FileHash $got).Hash -ne (Get-FileHash $want.FullName).Hash) {
      Write-Host "DIFF: $id/$name"
      git --no-pager diff --no-index --stat $want.FullName $got | Select-Object -First 8
      $failed = $true
    }
  }
}
Remove-Item -Recurse -Force $work
if ($failed) { Write-Host "samples/expected differs on Windows"; exit 1 }
Write-Host "samples/expected matches on Windows: $count programs"
