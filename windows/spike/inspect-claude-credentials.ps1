# Shows where Claude Code keeps its login on this PC, without printing any
# token. Paste the output into windows/docs/plan/phase-01-start.md.
#   powershell -ExecutionPolicy Bypass -File windows\spike\inspect-claude-credentials.ps1

$ErrorActionPreference = 'Continue'
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

# Claude Code's global config: <config dir>\.config.json when non-empty,
# else .claude.json in CLAUDE_CONFIG_DIR or the user profile.
$legacy = Join-Path $configDir '.config.json'
$globalConfig = if ((Test-Path $legacy) -and (Get-Item $legacy).Length -gt 0) { $legacy }
                elseif ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' }
                else { Join-Path $env:USERPROFILE '.claude.json' }

function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Describe-Json($text) {
  try {
    $j = $text | ConvertFrom-Json
    $keys = ($j.PSObject.Properties.Name) -join ', '
    $oauth = if ($j.claudeAiOauth) { ($j.claudeAiOauth.PSObject.Properties.Name) -join ', ' } else { '-' }
    "top-level keys: $keys | claudeAiOauth fields: $oauth"
  } catch { 'not JSON' }
}

Section 'Claude Code'
try { & claude --version } catch { Write-Host 'claude not on PATH' }

Section 'Backend switch'
Write-Host "CLAUDE_CONFIG_DIR = '$($env:CLAUDE_CONFIG_DIR)'"
Write-Host "CLAUDE_CODE_FORCE_WINDOWS_CREDMAN = '$($env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN)'"
Write-Host "global config: $globalConfig"
if (Test-Path $globalConfig) {
  try {
    $j = Get-Content $globalConfig -Raw | ConvertFrom-Json
    Write-Host "tengu_windows_credman = '$($j.cachedGrowthBookFeatures.tengu_windows_credman)'; oauthAccount present = $([bool]$j.oauthAccount.emailAddress)"
  } catch { Write-Host 'unreadable JSON' }
} else { Write-Host 'missing' }

Section 'Plaintext credentials file'
$cred = Join-Path $configDir '.credentials.json'
if (Test-Path $cred) {
  $raw = Get-Content $cred -Raw
  Write-Host "$cred : $($raw.Length) chars, modified $((Get-Item $cred).LastWriteTime)"
  Write-Host (Describe-Json $raw)
} else { Write-Host "$cred : missing" }

Section 'Credential Manager entries (metadata only)'
Add-Type -Namespace Spike -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
  public uint Flags; public uint Type; public string TargetName; public string Comment;
  public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
  public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredEnumerateW(string filter, uint flags, out uint count, out IntPtr creds);
[DllImport("advapi32.dll")] public static extern void CredFree(IntPtr buffer);
'@
$count = 0; $ptr = [IntPtr]::Zero
if ([Spike.Cred]::CredEnumerateW('*laude*', 0, [ref]$count, [ref]$ptr)) {
  for ($i = 0; $i -lt $count; $i++) {
    $p = [Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size)
    $c = [Runtime.InteropServices.Marshal]::PtrToStructure($p, [type][Spike.Cred+CREDENTIAL])
    $bytes = New-Object byte[] $c.CredentialBlobSize
    if ($c.CredentialBlobSize -gt 0) { [Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $bytes, 0, $bytes.Length) }
    $utf8 = [Text.Encoding]::UTF8.GetString($bytes); $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    $enc = if ($utf8.TrimStart().StartsWith('{')) { 'utf8' } elseif ($utf16.TrimStart([char]0xFEFF).StartsWith('{')) { 'utf16le' } else { 'unknown' }
    $text = if ($enc -eq 'utf16le') { $utf16.TrimStart([char]0xFEFF) } else { $utf8 }
    Write-Host ("target='{0}' type={1} persist={2} user='{3}' blob={4} bytes enc={5}" -f $c.TargetName, $c.Type, $c.Persist, $c.UserName, $c.CredentialBlobSize, $enc)
    if ($enc -ne 'unknown') { Write-Host ('  ' + (Describe-Json $text)) }
  }
  [Spike.Cred]::CredFree($ptr)
} else { Write-Host 'no matching entries' }

Section 'Claude Code runtime files'
$sessions = Join-Path $configDir 'sessions'
Write-Host "sessions dir: $(if (Test-Path $sessions) { (Get-ChildItem $sessions -Filter *.json).Count.ToString() + ' file(s)' } else { 'missing' })"
Write-Host "oauth refresh lock present: $(Test-Path (Join-Path $configDir '.oauth_refresh.lock'))"

Section 'Claude Swap data'
$data = Join-Path $env:APPDATA 'ClaudeSwap'
Write-Host "$data : $(if (Test-Path $data) { (Get-ChildItem $data -Recurse -File | Measure-Object).Count.ToString() + ' file(s)' } else { 'not created yet' })"
