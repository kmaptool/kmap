; The Windows installer for kmap. Built by Scripts/windows-package.ps1, which passes in
; the version, the architectures and the payload folder.
;
; Ordinary on purpose: Program Files, a Start-menu entry, a desktop shortcut, an entry in
; Add or Remove Programs. kmap arrives with its Swift runtime beside it and needs nothing
; else on the machine; Java, mkgmap and the rest it installs for itself.

; Defaults, so the file opens in the Inno Setup editor without arguments.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef Payloads
  #define Payloads "..\build\windows\payload"
#endif
; "-x64" or "-arm64" when the installer carries one architecture; empty when both.
#ifndef Suffix
  #define Suffix ""
#endif
; Which payloads are present. An installer carrying both lays down only the matching one.
#if !defined(Hasarm64) && !defined(Hasx64)
  #define Hasarm64 1
#endif

[Setup]
AppId={{9F2B4E31-6C4A-4E5F-9D3B-7A1C0E8D5B42}
AppName=kmap
AppVersion={#AppVersion}
AppPublisher=kmap
AppSupportURL=https://github.com/kmaptool/kmap
DefaultDirName={autopf}\kmap
DefaultGroupName=kmap
DisableProgramGroupPage=yes
OutputBaseFilename=kmap-{#AppVersion}{#Suffix}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-machine when possible, per-user without administrator rights.
PrivilegesRequiredOverridesAllowed=dialog
#if defined(Hasarm64) && defined(Hasx64)
ArchitecturesAllowed=arm64 x64compatible
ArchitecturesInstallIn64BitMode=arm64 x64compatible
#elif defined(Hasarm64)
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64compatible rather than x64: an ARM64 Windows can run this emulated.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
UninstallDisplayName=kmap {#AppVersion}
; kmap.exe carries the same icon as a resource; this is the installer's own.
; IconFile is passed in as an absolute path, and only when the file exists.
#ifdef IconFile
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\kmap.ico
#else
UninstallDisplayIcon={app}\kmap.exe
#endif
; Windows 10 1803: the console understands VT sequences (1511) and sends them on input
; (1607), and `tar` ships with Windows (1803), which is how kmap unpacks its downloads.
MinVersion=10.0.17134

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
; Off by default: changing the PATH is the user's decision.
Name: "addtopath"; Description: "Add kmap to PATH"; Flags: unchecked

[Files]
; The binary and the Swift runtime beside it. Both payloads are compressed into the
; installer; only the matching one is written to disk.
#ifdef Hasarm64
Source: "{#Payloads}\arm64\*"; DestDir: "{app}"; Check: IsArm64; \
    Flags: ignoreversion recursesubdirs createallsubdirs solidbreak
#endif
#ifdef Hasx64
Source: "{#Payloads}\x64\*"; DestDir: "{app}"; Check: not IsArm64; \
    Flags: ignoreversion recursesubdirs createallsubdirs solidbreak
#endif
#ifdef IconFile
Source: "{#IconFile}"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
#ifdef IconFile
Name: "{group}\kmap"; Filename: "{app}\kmap.exe"; IconFilename: "{app}\kmap.ico"
Name: "{group}\{cm:UninstallProgram,kmap}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\kmap"; Filename: "{app}\kmap.exe"; IconFilename: "{app}\kmap.ico"; \
    Tasks: desktopicon
#else
Name: "{group}\kmap"; Filename: "{app}\kmap.exe"
Name: "{group}\{cm:UninstallProgram,kmap}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\kmap"; Filename: "{app}\kmap.exe"; Tasks: desktopicon
#endif

[Run]
Filename: "{app}\kmap.exe"; Description: "{cm:LaunchProgram,kmap}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKA; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
    ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NotAlreadyOnPath

[Code]
{ Adding a folder that is already there would grow the PATH by one copy per reinstall. }
function NotAlreadyOnPath: Boolean;
var
  Existing: string;
begin
  Result := True;
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Existing) then
    Result := Pos(Lowercase(ExpandConstant('{app}')), Lowercase(Existing)) = 0;
end;
