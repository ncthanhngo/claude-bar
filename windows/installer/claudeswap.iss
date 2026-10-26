; Claude Swap installer — per-user, no admin rights.
; Build on Windows:  iscc /DAppVersion=0.1.0 /DArch=amd64 installer\claudeswap.iss
; Expects dist\windows-<Arch>\{ClaudeSwap.exe,csw.exe} from `make build`.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "amd64"
#endif

[Setup]
AppId={{6F1C2B7E-4E0D-4C55-9E3A-2C1B0D5A7F31}
AppName=Claude Swap
AppVersion={#AppVersion}
AppPublisher=Thanh Ngo
AppPublisherURL=https://github.com/ncthanhngo/claude-bar
DefaultDirName={localappdata}\Programs\ClaudeSwap
DefaultGroupName=Claude Swap
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=ClaudeSwap-{#AppVersion}-windows-{#Arch}-setup
SetupIconFile=..\internal\tray\icon.ico
UninstallDisplayIcon={app}\ClaudeSwap.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
; Same name the tray uses (Local\ClaudeSwapTray): setup and uninstall ask
; the user to quit it first. x64compatible needs Inno Setup 6.3+.
AppMutex=ClaudeSwapTray
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "autostart"; Description: "Start Claude Swap when I sign in to Windows"

[Files]
Source: "..\dist\windows-{#Arch}\ClaudeSwap.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\windows-{#Arch}\csw.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Claude Swap"; Filename: "{app}\ClaudeSwap.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ClaudeSwap"; ValueData: """{app}\ClaudeSwap.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\ClaudeSwap.exe"; Description: "Start Claude Swap now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\ClaudeSwap"

[Code]
// Saved accounts (encrypted backups + account list) are kept unless the
// user asks to remove them. Claude Code's own login is never touched.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and
     (SuppressibleMsgBox('Also remove the accounts saved by Claude Swap?' + #13#10 +
             'Claude Code stays logged in to its current account either way.',
             mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES) then
    DelTree(ExpandConstant('{userappdata}\ClaudeSwap'), True, True, True);
end;
