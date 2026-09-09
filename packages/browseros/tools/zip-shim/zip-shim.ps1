param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Args_)

$ErrorActionPreference = 'Stop'

$output = $null
$members = @()
foreach ($arg in $Args_) {
    if ($arg -in '-X', '-q', '-r') { continue }
    if ([string]::IsNullOrWhiteSpace($output)) {
        $output = $arg
        continue
    }
    # Info-ZIP stores members without a leading ./ and never archives the cwd
    # itself as an entry; tar keeps both verbatim, so normalize to match.
    $member = $arg
    if ($member -eq '.' -or $member -eq './' -or $member -eq '.\') {
        $cwd = (Get-Location).Path
        $members += @(Get-ChildItem -LiteralPath $cwd -Recurse -File |
            ForEach-Object { $_.FullName.Substring($cwd.Length + 1).Replace('\', '/') })
    } else {
        if ($member.StartsWith('./')) { $member = $member.Substring(2) }
        elseif ($member.StartsWith('.\')) { $member = $member.Substring(2).Replace('\', '/') }
        $members += $member.TrimEnd('/')
    }
}

if ([string]::IsNullOrWhiteSpace($output) -or $members.Count -eq 0) {
    Write-Error "usage: zip [-X] [-q] [-r] <out.zip> <member...>"
    exit 2
}

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
& $tar '-a' '-c' '-f' $output @members
exit $LASTEXITCODE
