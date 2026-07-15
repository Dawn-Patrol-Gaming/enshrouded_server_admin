{
NOTE: in the manifest it's designated to run with elevated privileges, this is
because the app can't attach to another console without it in most cases. In order
to debug either drop the requirement (therefore may not be able to attach to a
console) or run the IDE as admin/elevated
}
program EnshroudedServerRestart;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.Windows, Winapi.TlHelp32, System.SysUtils, System.DateUtils, System.IOUtils,
  System.IniFiles, System.SyncObjs, System.Classes, System.Zip, System.Masks;

const
  ATTACH_PARENT_PROCESS = DWORD(-1);

var
  LogFileName: string; // date-stamped log file, set in InitLogging
  LogCriticalSection: TCriticalSection;

  {
  Reattach our process to its original (parent / cmd) console after we've been
  attached to the server's console. Falls back to a fresh console only if there
  is no parent console (e.g. launched non-interactively by Task Scheduler).
  }
procedure RestoreOwnConsole;
begin
  if not AttachConsole(ATTACH_PARENT_PROCESS) then
    AllocConsole;
  // After FreeConsole/AttachConsole the console's std handles change, but the
  // RTL's Input/Output/ErrOutput text files still cache the original (now
  // invalid) handles — the next Writeln would raise I/O error 6. Rebind them.
  TTextRec(Input).Handle := GetStdHandle(STD_INPUT_HANDLE);
  TTextRec(Output).Handle := GetStdHandle(STD_OUTPUT_HANDLE);
  TTextRec(ErrOutput).Handle := GetStdHandle(STD_ERROR_HANDLE);
end;

{
---------------------------------------------------------------------------
Configuration — loaded at runtime from EnshroudedServerRestart.ini (next to the
exe). File name of the ini is determined by executable name, default
"EnshroudedServerRestart".
---------------------------------------------------------------------------
}
var
  SERVER_EXE_NAME: string; // Executable name as shown in Task Manager
  SERVER_EXE_PATH: string; // Full path to the server executable
  SERVER_WORK_DIR: string; // Working directory for the server process
  SERVER_ARGS: string; // Command-line arguments on restart ('' if none — Enshrouded reads enshrouded_server.json instead)
  SHUTDOWN_TIMEOUT: Integer; // Seconds to wait for clean shutdown
  RESTART_DELAY: Integer; // Seconds to wait between stop and start
  SAVE_DIR: string; // Folder containing the savegame files to back up ('' = skip backup)
  BACKUP_DIR: string; // Folder where the zipped backup is written
  SAVE_PREFIX: string; // Prefix on the savegame backup file name (may be blank)
  SAVE_SUFFIX: string; // Suffix on the savegame backup file name, before .zip (may be blank)
  SETTINGS_DIR: string; // Folder holding enshrouded_server.json to back up ('' = skip)
  SETTINGS_MASK: string; // File mask for the settings backup (default *.json)
  SETTINGS_PREFIX: string; // Prefix on the settings backup file name (may be blank)
  SETTINGS_SUFFIX: string; // Suffix on the settings backup file name, before .zip (may be blank)
  EXCLUDE_MASKS: string; // Semicolon-separated name masks excluded from the regular backups (e.g. *.old;*.tmp); '' = exclude nothing
  SERVER_LOG_DIR: string; //Enshrouded server log folder to purge after a successful backup ('' = skip)
  AUTO_ARCHIVE_DIR: string; // Destination folder for /autoarchive zips
  AUTO_PREFIX: string; // Prefix on the auto-archive file name (may be blank)
  AUTO_SUFFIX: string; // Suffix on the auto-archive file name, before .zip (may be blank)
  AUTO_SAVE_ID: string; // Save id (base file name, e.g. 3ad85aea); '' = auto-detect via *-index files
  AUTO_PAIR_TOLERANCE: Integer; // Max seconds between -index and the newest slot to count as one flush
  AUTO_MIN_AGE: Integer; // Save set must be at least this many seconds old (i.e. flush finished)
  AUTO_WAIT_TIMEOUT: Integer; // Max seconds to wait for a consistent save set before giving up
  ENABLE_UPDATE: Boolean; // Whether to run a SteamCMD update before restart
  STEAMCMD_PATH: string; // Full path to steamcmd.exe
  STEAM_APP_ID: string; // Steam app id for the Enshrouded dedicated server (configurable)
  STEAM_INSTALL_DIR: string; // +force_install_dir target (server root)

function ConfigPath: string;
begin
  // Same folder as the exe, regardless of the current working directory.
  Result := TPath.ChangeExtension(ParamStr(0), '.ini');
end;

{
Reads a key, but if it does not yet exist in the file, writes the supplied
default back first. This makes the config self-healing: when an existing user
upgrades to a build with new options, those options are appended to their .ini
with sensible defaults rather than silently using them in-memory only.
}
function EnsureString(Ini: TIniFile; const Section, Key, Default: string): string;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteString(Section, Key, Default);
  Result := Ini.ReadString(Section, Key, Default);
end;

function EnsureInteger(Ini: TIniFile; const Section, Key: string; Default: Integer): Integer;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteInteger(Section, Key, Default);
  Result := Ini.ReadInteger(Section, Key, Default);
end;

{
Loads configuration, creating the file if missing and filling in any missing
keys with defaults (see EnsureString/EnsureInteger). Returns False if the file
was just created (so the caller stops and lets the user edit it) or if a
required value is missing.
}
function LoadConfig: Boolean;
var
  Ini: TIniFile;
  Path: string;
  FreshFile: Boolean;
begin
  Result := False;
  Path := ConfigPath;
  FreshFile := not TFile.Exists(Path);

  Ini := TIniFile.Create(Path);
  try
    SERVER_EXE_NAME := EnsureString(Ini, 'Server', 'ExeName', 'enshrouded_server.exe');
    SERVER_EXE_PATH := EnsureString(Ini, 'Server', 'ExePath', 'C:\SteamCMD\enshrouded_server\enshrouded_server.exe');
    SERVER_WORK_DIR := EnsureString(Ini, 'Server', 'WorkDir', 'C:\SteamCMD\enshrouded_server\');
    // Enshrouded takes no meaningful command-line arguments: everything (name,
    // password, ports, save/log dirs) lives in enshrouded_server.json in the
    // working directory. Blank is the correct default.
    SERVER_ARGS := EnsureString(Ini, 'Server', 'Args', '');
    SHUTDOWN_TIMEOUT := EnsureInteger(Ini, 'Restart', 'ShutdownTimeoutSec', 120);
    RESTART_DELAY := EnsureInteger(Ini, 'Restart', 'RestartDelaySec', 10);
    SAVE_DIR := EnsureString(Ini, 'Backup', 'SaveDir', 'C:\SteamCMD\enshrouded_server\savegame');
    BACKUP_DIR := EnsureString(Ini, 'Backup', 'BackupDir', 'C:\Enshrouded_Backups');
    SAVE_PREFIX := EnsureString(Ini, 'Backup', 'SaveBackupPrefix', '');
    SAVE_SUFFIX := EnsureString(Ini, 'Backup', 'SaveBackupSuffix', '');
    SETTINGS_DIR := EnsureString(Ini, 'Backup', 'SettingsDir', 'C:\SteamCMD\enshrouded_server');
    SETTINGS_MASK := EnsureString(Ini, 'Backup', 'SettingsMask', '*.json');
    SETTINGS_PREFIX := EnsureString(Ini, 'Backup', 'SettingsBackupPrefix', 'settings_');
    SETTINGS_SUFFIX := EnsureString(Ini, 'Backup', 'SettingsBackupSuffix', '');
    EXCLUDE_MASKS := EnsureString(Ini, 'Backup', 'ExcludeMasks', '');
    SERVER_LOG_DIR := EnsureString(Ini, 'Cleanup', 'ServerLogDir', '');
    AUTO_ARCHIVE_DIR := EnsureString(Ini, 'AutoArchive', 'ArchiveDir', 'C:\Enshrouded_Backups\auto');
    AUTO_PREFIX := EnsureString(Ini, 'AutoArchive', 'ArchivePrefix', 'auto_');
    AUTO_SUFFIX := EnsureString(Ini, 'AutoArchive', 'ArchiveSuffix', '');
    AUTO_SAVE_ID := EnsureString(Ini, 'AutoArchive', 'SaveId', '');
    AUTO_PAIR_TOLERANCE := EnsureInteger(Ini, 'AutoArchive', 'PairToleranceSec', 2);
    AUTO_MIN_AGE := EnsureInteger(Ini, 'AutoArchive', 'MinAgeSec', 10);
    AUTO_WAIT_TIMEOUT := EnsureInteger(Ini, 'AutoArchive', 'WaitTimeoutSec', 120);
    ENABLE_UPDATE := EnsureInteger(Ini, 'Update', 'EnableUpdate', 0) <> 0;
    STEAMCMD_PATH := EnsureString(Ini, 'Update', 'SteamCmdPath', 'C:\SteamCMD\steamcmd.exe');
    STEAM_APP_ID := EnsureString(Ini, 'Update', 'SteamAppId', '2278520');
    STEAM_INSTALL_DIR := EnsureString(Ini, 'Update', 'InstallDir', 'C:\SteamCMD\enshrouded_server');
  finally
    Ini.Free;
  end;

  if FreshFile then
  begin
    Writeln('A default configuration file was created:');
    Writeln('  ' + Path);
    Writeln('Edit it to match your server, then run this program again.');
    Exit;
  end;

  if (SERVER_EXE_NAME = '') or (SERVER_EXE_PATH = '') then
  begin
    Writeln('ERROR: ExeName and ExePath must be set in ' + Path);
    Exit;
  end;

  // Default the working directory to the exe's folder if not specified.
  if SERVER_WORK_DIR = '' then
    SERVER_WORK_DIR := ExtractFilePath(SERVER_EXE_PATH);

  Result := True;
end;
// ---------------------------------------------------------------------------

function FindProcessByName(const ExeName: string): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if SameText(string(Entry.szExeFile), ExeName) then
        begin
          Result := Entry.th32ProcessID;
          Break;
        end; //if SameText(string(Entry.szExeFile), ExeName) then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function GetParentPID(PID: DWORD): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := Entry.th32ParentProcessID;
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function SessionOf(PID: DWORD): DWORD;
begin
  if not ProcessIdToSessionId(PID, Result) then
    Result := DWORD(-1);
end;

const
  // Redeclared locally so the code compiles regardless of Delphi version.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

// Not declared in every Delphi version's Winapi.Windows, so bind it directly.
function GetConsoleProcessList(lpdwProcessList: PDWORD; dwProcessCount: DWORD): DWORD; stdcall;
  external kernel32 name 'GetConsoleProcessList';

{
Executable name of a process, via the same Toolhelp snapshot the other process
helpers use. Returns '?' if the PID no longer exists.
}
function ExeNameOfPID(PID: DWORD): string;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := '?';
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := string(Entry.szExeFile);
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

{
Lists every process attached to the console we are CURRENTLY attached to, as
'name(PID)' pairs. These are exactly the processes a GenerateConsoleCtrlEvent
broadcast to group 0 will reach, so TrySignalViaConsole records this before
sending Ctrl+C: any unexpected entry in the logged list (a cmd.exe mid-batch,
BEC, ...) names an innocent bystander that took our signal. Never raises.
}
function DescribeConsoleProcesses: string;
var
  PIDs: array[0..63] of DWORD;
  Count: DWORD;
  i: Integer;
begin
  Count := GetConsoleProcessList(@PIDs[0], Length(PIDs));
  if Count = 0 then
    Exit('(GetConsoleProcessList failed: ' + SysErrorMessage(GetLastError) + ')');
  if Count > DWORD(Length(PIDs)) then
    Count := DWORD(Length(PIDs)); // more than 64 attached: report the first 64
  Result := '';
  for i := 0 to Integer(Count) - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ExeNameOfPID(PIDs[i]) + '(' + PIDs[i].ToString + ')';
  end; //for i := 0 to Integer(Count) - 1 do
end;

{
Guards the parent-PID retry in ShutdownServerGracefully against PID reuse:
th32ParentProcessID is only a number - if the original launcher has exited,
the same PID may since have been recycled by a completely unrelated process
(e.g. the cmd.exe running another game's restart batch). Attaching to THAT
process's console and broadcasting Ctrl+C would signal every innocent process
on it. So the parent is only trusted if it (a) still exists, (b) lives in the
same session as the server, and (c) was created BEFORE the server - a recycled
PID is always younger than the child it supposedly spawned. Returns True when
the parent looks genuine; otherwise False with Reason for the caller to log.
}
function ParentLooksGenuine(ParentPID, ChildPID: DWORD; out Reason: string): Boolean;
var
  hParent, hChild: THandle;
  ParentCreate, ChildCreate, ftExit, ftKernel, ftUser: TFileTime;
begin
  Result := False;
  Reason := '';

  hParent := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ParentPID);
  if hParent = 0 then
  begin
    Reason := 'parent PID ' + ParentPID.ToString + ' cannot be opened (probably exited): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hParent = 0 then
  try
    hChild := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ChildPID);
    if hChild = 0 then
    begin
      Reason := 'server PID ' + ChildPID.ToString + ' cannot be opened: ' + SysErrorMessage(GetLastError);
      Exit;
    end; //if hChild = 0 then
    try
      if SessionOf(ParentPID) <> SessionOf(ChildPID) then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ') is in session ' +
          SessionOf(ParentPID).ToString + ' but the server is in session ' + SessionOf(ChildPID).ToString +
          ' - not the real launcher';
        Exit;
      end; //if SessionOf(ParentPID) <> SessionOf(ChildPID) then

      if not GetProcessTimes(hParent, ParentCreate, ftExit, ftKernel, ftUser) or
         not GetProcessTimes(hChild, ChildCreate, ftExit, ftKernel, ftUser) then
      begin
        Reason := 'GetProcessTimes failed: ' + SysErrorMessage(GetLastError);
        Exit;
      end; //if not GetProcessTimes(...) then

      if CompareFileTime(ParentCreate, ChildCreate) > 0 then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) +
          ') was created AFTER the server - the PID was recycled by an unrelated process';
        Exit;
      end; //if CompareFileTime(ParentCreate, ChildCreate) > 0 then

      Result := True;
    finally
      CloseHandle(hChild);
    end;
  finally
    CloseHandle(hParent);
  end;
end;

{
Appends a timestamped line to TheFile, creating it (and any missing parent
folders) as needed. Thread-safe and never raises — logging must not become a
new failure point.
}
procedure LogIt(const TheMsg, TheFile: string);
var
  fs: TFileStream;
  Buf: TBytes;
  TheDir, TheMessage: string;
begin
  try
    LogCriticalSection.Enter;
    try
      fs := nil;
      try
        TheDir := ExtractFilePath(TheFile);
        if (TheDir <> '') and not DirectoryExists(TheDir) then
          ForceDirectories(TheDir);
        try
          fs := TFileStream.Create(TheFile, fmOpenReadWrite or fmShareDenyNone);
        except
          fs := TFileStream.Create(TheFile, fmCreate);
        end;
        fs.Seek(0, soFromEnd);
        TheMessage := FormatDateTime('yyyy-mm-dd hh:nn:ssAM/PM', Now) + ' - ' + TheMsg + sLineBreak;
        Buf := TEncoding.Default.GetBytes(TheMessage);
        fs.Write(Buf[0], Length(Buf));
      finally
        fs.Free;
      end;
    finally
      LogCriticalSection.Leave;
    end;
  except
    // swallow any logging error so it never breaks the actual work.
  end;
end;

{
Sets up the date-stamped log file
(logs\EnshroudedServerRestart\EnshroudedServerRestart_yyyy-mm-dd.log next to
the exe) and creates the critical section LogIt requires. The extra per-app
subfolder under logs\ is deliberate: several of these restart utilities
(SCUM/Valheim/Enshrouded) can run side by side from ONE folder, and each keeps
its logs in its own subfolder named after its exe. LogIt creates the folders
on first write.
}
procedure InitLogging;
var
  AppName: string;
begin
  if not Assigned(LogCriticalSection) then
    LogCriticalSection := TCriticalSection.Create;
  AppName := TPath.GetFileNameWithoutExtension(ParamStr(0));
  LogFileName := TPath.Combine(TPath.Combine(TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), AppName),
    AppName + '_' + FormatDateTime('yyyy-mm-dd', Now) + '.log');
end;

{ Writes to both the console and the date-stamped log file. }
procedure Log(const Msg: string);
begin
  Writeln(Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Msg]));
  LogIt(Msg, LogFileName); // LogIt prepends its own timestamp
end;
{
Sends a real Ctrl+C (CTRL_C_EVENT) to the Enshrouded server console and waits
for the process to exit. enshrouded_server.exe is a console-subsystem app and
Ctrl+C is the developer-documented way to stop it: its console control handler
writes a fresh rolling world save and exits cleanly. Window messages (WM_CLOSE
etc.) do NOT trigger this — only a genuine console control signal does. A hard
kill (Task Manager / Stop-Process -Force) skips the shutdown save and is the
leading cause of corrupted/rolled-back worlds.

Verified sequence:
  1. Open a handle to the target so we can wait on it afterwards.
  2. Detach our own console, attach to the server's console.
  3. Disable Ctrl handling for OURSELVES (the event broadcasts to every
     process on the console group, including this one — without this we'd
     kill ourselves before we could wait/restart).
  4. GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) — 0 = whole console group.
  5. Wait for the target to exit (while still attached). Save time scales
     with world size / player count, so poll up to the timeout in the ini.
     Increase the timeout if necessary in the ini file.
  6. Detach, re-enable our Ctrl handling, restore our own console.

NOTE: while attached to the server's console, Writeln goes to THAT console,
not ours — so we buffer status and log it only after we've restored our own.
Attaches to AttachPID's console, sends Ctrl+C to the whole group, then waits
for WaitPID (the actual server) to exit. AttachPID may be the server itself
or its console-owning parent. Returns True if the server exited in time.
StatusMsg / Attached report what happened (logged by the caller after the
console is restored — we must not Log() while attached to another console).
}
function TrySignalViaConsole(AttachPID, WaitPID: DWORD; TimeoutSec: Integer; out Attached: Boolean; out StatusMsg: string): Boolean;
var
  hProc: THandle;
  WaitResult, AttachErr: DWORD;
  SignalSent: Boolean;
  ConsoleProcs: string;
begin
  Result := False;
  Attached := False;

  hProc := OpenProcess(SYNCHRONIZE, False, WaitPID);
  if hProc = 0 then
  begin
    StatusMsg := 'ERROR: Cannot open server process (PID ' + WaitPID.ToString + '): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hProc = 0 then

  try
    FreeConsole;
    if not AttachConsole(AttachPID) then
    begin
      AttachErr := GetLastError;
      RestoreOwnConsole;
      StatusMsg := 'AttachConsole(PID ' + AttachPID.ToString + ') failed: ' + SysErrorMessage(AttachErr);
      Exit;
    end; //if not AttachConsole(AttachPID) then
    Attached := True;

    // Do NOT Log() past this point — output would go to the attached console.
    // Record who shares this console BEFORE signalling: the CTRL_C_EVENT
    // broadcast below reaches every one of these processes, so this list
    // (appended to StatusMsg and logged by the caller) names any innocent
    // bystander that took the signal (a cmd.exe mid-batch, BEC, ...).
    ConsoleProcs := DescribeConsoleProcesses;

    SetConsoleCtrlHandler(nil, True); // don't let the signal kill us
    SignalSent := GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);

    if SignalSent then
    begin
      WaitResult := WaitForSingleObject(hProc, DWORD(TimeoutSec) * 1000);
      Result := (WaitResult = WAIT_OBJECT_0);
      if Result then
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ' - server exited cleanly.'
      else
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ', but server did not exit within ' + TimeoutSec.ToString + 's.';
    end //if SignalSent then
    else
      StatusMsg := 'GenerateConsoleCtrlEvent failed: ' + SysErrorMessage(GetLastError);

    StatusMsg := StatusMsg + ' [console group: ' + ConsoleProcs + ']';

    SetConsoleCtrlHandler(nil, False);
    FreeConsole;
    RestoreOwnConsole;
  finally
    CloseHandle(hProc);
  end;
end;

function ShutdownServerGracefully(PID: DWORD; TimeoutSec: Integer): Boolean;
var
  ParentPID: DWORD;
  Attached: Boolean;
  StatusMsg, Reason: string;
begin
  Log('Server session=' + SessionOf(PID).ToString + ', ' + ExtractFileName(ParamStr(0)) + ' session=' + SessionOf(GetCurrentProcessId).ToString +
    '.');

  // First attempt: attach to the server's own console.
  Result := TrySignalViaConsole(PID, PID, TimeoutSec, Attached, StatusMsg);
  Log(StatusMsg);
  if Result then
    Exit;

  // If the attach itself failed, the console is probably owned by a parent launcher (batch/Steam/wrapper). Try attaching to that instead.
  if not Attached then
  begin
    ParentPID := GetParentPID(PID);
    if (ParentPID <> 0) and (ParentPID <> PID) then
    begin
      // Vet the recorded parent before attaching: its PID may have been
      // recycled by an unrelated process since the server was launched (see
      // ParentLooksGenuine) - Ctrl+C into that console would hit innocents.
      if ParentLooksGenuine(ParentPID, PID, Reason) then
      begin
        Log('Retrying via parent process PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ', session=' +
          SessionOf(ParentPID).ToString + ')...');
        Result := TrySignalViaConsole(ParentPID, PID, TimeoutSec, Attached, StatusMsg);
        Log(StatusMsg);
      end //if ParentLooksGenuine(ParentPID, PID, Reason) then
      else
        Log('NOT retrying via parent PID ' + ParentPID.ToString + ': ' + Reason);
    end //if (ParentPID <> 0) and (ParentPID <> PID) then
    else
      Log('No usable parent process to retry against.');
  end; //if not Attached then
end;

{ True when FileName matches ANY mask in the semicolon-separated Masks list
  (blank entries are ignored). Used for the [Backup] ExcludeMasks option. }
function MatchesAnyMask(const FileName, Masks: string): Boolean;
var
  Mask: string;
begin
  Result := False;
  for Mask in Masks.Split([';']) do
    if (Trim(Mask) <> '') and MatchesMask(FileName, Trim(Mask)) then
      Exit(True);
end;

{
Zips files matching FileMask under SourceDir (recursively when Recurse is True,
preserving folder structure) into BACKUP_DIR as
<Prefix>yyyy_mm_dd_hh_nn_ss<Suffix>.zip. Prefix and Suffix may be blank. Files
whose NAME matches any mask in the semicolon-separated ExcludeMasks list are
left out ('' = exclude nothing). Meant to run while the server is stopped so
files are flushed and unlocked. Returns False on any problem (logged by the
caller); a failed backup is non-fatal.

Recurse=False exists for the settings backup: enshrouded_server.json sits in the
server INSTALL ROOT, and recursing from there would sweep up the whole install.
}
function ZipFolder(const Description, SourceDir, FileMask, Prefix, Suffix: string; Recurse: Boolean; const ExcludeMasks: string = ''): Boolean;
var
  Zip: TZipFile;
  Files: TArray<string>;
  SrcFile, ZipPath, RelName, BaseDir: string;
  SearchOption: TSearchOption;
  i, Kept: Integer;
begin
  Result := False;

  if (SourceDir = '') or (BACKUP_DIR = '') then
  begin
    Log(Description + ' backup skipped: source or BackupDir not set in ' + ConfigPath + '.');
    Exit;
  end;//if (SourceDir = '') or (BACKUP_DIR = '') then

  if not TDirectory.Exists(SourceDir) then
  begin
    Log('WARNING: ' + Description + ' backup skipped - folder not found: ' + SourceDir);
    Exit;
  end;//if not TDirectory.Exists(SourceDir) then

  try
    if not TDirectory.Exists(BACKUP_DIR) then
      TDirectory.CreateDirectory(BACKUP_DIR);

    ZipPath := TPath.Combine(BACKUP_DIR, Prefix + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + Suffix + '.zip');

    if Recurse then
      SearchOption := TSearchOption.soAllDirectories
    else
      SearchOption := TSearchOption.soTopDirectoryOnly;

    BaseDir := IncludeTrailingPathDelimiter(SourceDir);
    Files := TDirectory.GetFiles(SourceDir, FileMask, SearchOption);

    if ExcludeMasks <> '' then
    begin
      Kept := 0;
      for i := 0 to High(Files) do
        if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
        begin
          Files[Kept] := Files[i];
          Inc(Kept);
        end; //if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
      if Kept < Length(Files) then
        Log('  Excluded ' + (Length(Files) - Kept).ToString + ' ' + Description + ' file(s) matching "' + ExcludeMasks + '".');
      SetLength(Files, Kept);
    end; //if ExcludeMasks <> '' then

    if Length(Files) = 0 then
    begin
      Log('WARNING: No ' + Description + ' files found to back up in ' + SourceDir + '.');
      Exit;
    end;

    Log('Backing up ' + Length(Files).ToString + ' ' + Description + ' file(s) from ' + SourceDir + '...');

    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      for SrcFile in Files do
      begin
        // Preserve the folder structure relative to SourceDir inside the zip.
        RelName := SrcFile;
        if RelName.StartsWith(BaseDir, True) then
          RelName := RelName.Substring(Length(BaseDir));
        Zip.Add(SrcFile, RelName);
      end; //for SrcFile in Files do
      Zip.Close;
    finally
      Zip.Free;
    end;

    Log(Description + ' backup written: ' + ZipPath);
    Result := True;
  except
    on E: Exception do
      Log('WARNING: ' + Description + ' backup failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

{ Backs up the entire savegame folder (all files, including the rolling copies). }
function BackupSavegame: Boolean;
begin
  Result := ZipFolder('savegame', SAVE_DIR, '*', SAVE_PREFIX, SAVE_SUFFIX, True, EXCLUDE_MASKS);
end;

{
Backs up the server settings (enshrouded_server.json) into a separate zip.
Deliberately NON-recursive: SettingsDir is normally the install root, and only
the top-level *.json belongs in the settings backup.
}
function BackupServerSettings: Boolean;
begin
  Result := ZipFolder('settings', SETTINGS_DIR, SETTINGS_MASK, SETTINGS_PREFIX, SETTINGS_SUFFIX, False, EXCLUDE_MASKS);
end;

{
---------------------------------------------------------------------------
/autoarchive mode — back up the savegame WITHOUT touching the running server.
(The /autoarchive switch is the cross-tool standard for "back up while the
server runs" modes in the Dawn Patrol Gaming server utilities.)

Enshrouded flushes a world save roughly every 5-10 minutes, ROTATING through
slot files: <id>, <id>-1 .. <id>-n each take a turn as the newest save, and
<id>-index is rewritten on EVERY flush to point at the slot just written. So
the base <id> file is usually several rotations old — pairing -index with it
would only line up on the ~1-in-10 flush that lands on the base slot. The
reliable "flush complete" signal is: <id>-index and the NEWEST <id>* slot
carry (near-)identical timestamps and are a few seconds old. That's the
quiet window this mode waits for.

Sequence per attempt:
  1. Wait until, for every save set, <id>-index matches the newest <id>*
     slot within PairToleranceSec and is at least MinAgeSec old (poll every
     2s, up to WaitTimeoutSec).
  2. Snapshot those timestamps, then COPY the whole savegame folder
     (top level) to a staging folder — copying is fast, zipping is not.
  3. Re-read the timestamps. If a flush started during the copy the staging
     snapshot may be torn — discard it and go back to waiting.
  4. Zip the verified staging copy into [AutoArchive] ArchiveDir and
     remove staging.

Restores should use the slot the -index file points at (the newest one);
the older rotation slots in each zip give extra fallback points.
---------------------------------------------------------------------------
}

{
Finds the save set index file(s) in SAVE_DIR: <SaveId>-index from the ini if
set, otherwise every top-level "*-index" file. Returns full paths of the
-index files; each anchors a save set of rotation slots named <id>*.
}
function GetSaveIndexFiles: TArray<string>;
var
  IdxPath: string;
begin
  Result := nil;

  if AUTO_SAVE_ID <> '' then
  begin
    IdxPath := TPath.Combine(SAVE_DIR, AUTO_SAVE_ID + '-index');
    if TFile.Exists(IdxPath) then
      Result := [IdxPath];
    Exit;
  end; //if AUTO_SAVE_ID <> '' then

  Result := TDirectory.GetFiles(SAVE_DIR, '*-index', TSearchOption.soTopDirectoryOnly);
end;

{
Timestamp of the newest rotation slot in IndexFile's save set — the newest
top-level <id>* file that is not itself an -index file. Returns 0 if no slot
file exists at all.
}
function NewestSlotTime(const IndexFile: string): TDateTime;
var
  IdName, SlotFile: string;
  Slots: TArray<string>;
  Ts: TDateTime;
begin
  Result := 0;
  IdName := ExtractFileName(IndexFile);
  IdName := IdName.Substring(0, IdName.Length - Length('-index'));
  Slots := TDirectory.GetFiles(SAVE_DIR, IdName + '*', TSearchOption.soTopDirectoryOnly);
  for SlotFile in Slots do
  begin
    if SlotFile.EndsWith('-index', True) then
      Continue;
    Ts := TFile.GetLastWriteTime(SlotFile);
    if Ts > Result then
      Result := Ts;
  end; //for SlotFile in Slots do
end;

{
True when IndexFile and the newest slot of its save set were written within
PairToleranceSec of each other AND the newer of the two is at least MinAgeSec
old — i.e. the last flush is complete and no new flush has started.
}
function SaveSetIsConsistent(const IndexFile: string): Boolean;
var
  TsSlot, TsIndex, Newest: TDateTime;
begin
  Result := False;
  TsSlot := NewestSlotTime(IndexFile);
  if TsSlot = 0 then
    Exit; // an -index with no slot files — nothing coherent to back up yet
  TsIndex := TFile.GetLastWriteTime(IndexFile);
  if TsSlot > TsIndex then
    Newest := TsSlot
  else
    Newest := TsIndex;
  Result := (SecondsBetween(TsSlot, TsIndex) <= Int64(AUTO_PAIR_TOLERANCE)) and
    (SecondsBetween(Now, Newest) >= Int64(AUTO_MIN_AGE));
end;

{
True when no save set moved since the Before snapshot (1 ms tolerance).
Checks both the -index timestamp and the newest-slot timestamp: a flush
touches a slot file first and the index last, so either one changing means
the staging copy may be torn.
}
function SaveSetsUnchanged(const IndexFiles: TArray<string>; const BeforeIdx, BeforeSlot: TArray<TDateTime>): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 0 to High(IndexFiles) do
    if (not SameDateTime(TFile.GetLastWriteTime(IndexFiles[i]), BeforeIdx[i])) or
       (not SameDateTime(NewestSlotTime(IndexFiles[i]), BeforeSlot[i])) then
      Exit(False);
end;

{
The /autoarchive mode driver. Returns the process exit code:
0 = backup written, 5 = failed or no consistent save appeared in time.
}
function AutoArchive: Integer;
var
  IdxFiles, SrcFiles, Stale: TArray<string>;
  BeforeIdx, BeforeSlot: TArray<TDateTime>;
  StagingDir, ZipPath, SrcFile, ADir, IdName: string;
  Zip: TZipFile;
  StartTick: UInt64;
  AllConsistent, WaitingLogged: Boolean;
  i: Integer;
begin
  Result := 5;

  if (SAVE_DIR = '') or (AUTO_ARCHIVE_DIR = '') then
  begin
    Log('ERROR: Auto-backup archive skipped - SaveDir or ArchiveDir not set in ' + ConfigPath + '.');
    Exit;
  end; //if (SAVE_DIR = '') or (AUTO_ARCHIVE_DIR = '') then

  if not TDirectory.Exists(SAVE_DIR) then
  begin
    Log('ERROR: Auto-backup archive skipped - folder not found: ' + SAVE_DIR);
    Exit;
  end; //if not TDirectory.Exists(SAVE_DIR) then

  IdxFiles := GetSaveIndexFiles;
  if Length(IdxFiles) = 0 then
  begin
    if AUTO_SAVE_ID <> '' then
      Log('ERROR: Save index "' + AUTO_SAVE_ID + '-index" not found in ' + SAVE_DIR + '.')
    else
      Log('ERROR: No *-index save file found in ' + SAVE_DIR + '.');
    Exit;
  end; //if Length(IdxFiles) = 0 then

  for i := 0 to High(IdxFiles) do
  begin
    IdName := ExtractFileName(IdxFiles[i]);
    IdName := IdName.Substring(0, IdName.Length - Length('-index'));
    Log('Watching save set: ' + IdName + ' (rotation slots + ' + IdName + '-index)');
  end; //for i := 0 to High(IdxFiles) do

  try
    if not TDirectory.Exists(AUTO_ARCHIVE_DIR) then
      TDirectory.CreateDirectory(AUTO_ARCHIVE_DIR);

    // Sweep staging leftovers from a previous crashed/killed run.
    Stale := TDirectory.GetDirectories(AUTO_ARCHIVE_DIR, '.staging_*', TSearchOption.soTopDirectoryOnly);
    for ADir in Stale do
      try
        TDirectory.Delete(ADir, True);
        Log('Removed stale staging folder: ' + ADir);
      except
        // ignore — a locked leftover only wastes disk, it can't corrupt anything
      end;
  except
    on E: Exception do
    begin
      Log('ERROR: Cannot prepare ' + AUTO_ARCHIVE_DIR + ': ' + E.ClassName + ' - ' + E.Message);
      Exit;
    end; //on E: Exception do
  end;

  WaitingLogged := False;
  StartTick := GetTickCount64;
  while (GetTickCount64 - StartTick) < UInt64(AUTO_WAIT_TIMEOUT) * 1000 do
  begin
    AllConsistent := True;
    for i := 0 to High(IdxFiles) do
      if not SaveSetIsConsistent(IdxFiles[i]) then
      begin
        AllConsistent := False;
        Break;
      end; //if not SaveSetIsConsistent(IdxFiles[i]) then

    if not AllConsistent then
    begin
      if not WaitingLogged then
      begin
        Log('-index and newest save slot timestamps differ or are too fresh (a flush may be in progress). Waiting up to ' + AUTO_WAIT_TIMEOUT.ToString + 's...');
        WaitingLogged := True;
      end; //if not WaitingLogged then
      Sleep(2000);
      Continue;
    end; //if not AllConsistent then

    // Snapshot the index + newest-slot timestamps, then copy everything to staging.
    SetLength(BeforeIdx, Length(IdxFiles));
    SetLength(BeforeSlot, Length(IdxFiles));
    for i := 0 to High(IdxFiles) do
    begin
      BeforeIdx[i] := TFile.GetLastWriteTime(IdxFiles[i]);
      BeforeSlot[i] := NewestSlotTime(IdxFiles[i]);
    end; //for i := 0 to High(IdxFiles) do

    StagingDir := TPath.Combine(AUTO_ARCHIVE_DIR, '.staging_' + FormatDateTime('hhnnsszzz', Now));
    try
      SrcFiles := TDirectory.GetFiles(SAVE_DIR, '*', TSearchOption.soTopDirectoryOnly);
      // Say explicitly what was (or wasn't) found, so the log alone answers
      // whether the backup had anything to work with.
      if Length(SrcFiles) = 0 then
      begin
        Log('ERROR: No files found to back up in ' + SAVE_DIR + ' - nothing was archived.');
        Exit;
      end; //if Length(SrcFiles) = 0 then
      Log('Found ' + Length(SrcFiles).ToString + ' file(s) to back up in ' + SAVE_DIR + '.');
      TDirectory.CreateDirectory(StagingDir);
      for SrcFile in SrcFiles do
        TFile.Copy(SrcFile, TPath.Combine(StagingDir, ExtractFileName(SrcFile)), True);
    except
      on E: Exception do
      begin
        // Most likely a file briefly locked by a starting save tick — retry.
        Log('Copy to staging failed (' + E.Message + ') - retrying...');
        try
          if TDirectory.Exists(StagingDir) then
            TDirectory.Delete(StagingDir, True);
        except
        end;
        Sleep(2000);
        Continue;
      end; //on E: Exception do
    end;

    // A save tick that started mid-copy means the staging snapshot may mix
    // old and new files — throw it away and wait for the next quiet window.
    if not SaveSetsUnchanged(IdxFiles, BeforeIdx, BeforeSlot) then
    begin
      Log('A save flush started during the copy - discarding this snapshot and retrying...');
      try
        TDirectory.Delete(StagingDir, True);
      except
      end;
      WaitingLogged := False;
      Sleep(2000);
      Continue;
    end; //if not SaveSetsUnchanged(IdxFiles, BeforeIdx, BeforeSlot) then

    // Verified snapshot: zip it (flat — savegame is a flat folder) and clean up.
    try
      ZipPath := TPath.Combine(AUTO_ARCHIVE_DIR, AUTO_PREFIX + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + AUTO_SUFFIX + '.zip');
      SrcFiles := TDirectory.GetFiles(StagingDir, '*', TSearchOption.soTopDirectoryOnly);
      Log('Zipping ' + Length(SrcFiles).ToString + ' savegame file(s)...');
      Zip := TZipFile.Create;
      try
        Zip.Open(ZipPath, zmWrite);
        for SrcFile in SrcFiles do
          Zip.Add(SrcFile, ExtractFileName(SrcFile));
        Zip.Close;
      finally
        Zip.Free;
      end;
      Log('Auto-backup archive written: ' + ZipPath);
      Result := 0;
    except
      on E: Exception do
        Log('ERROR: Auto-backup archive zip failed: ' + E.ClassName + ' - ' + E.Message);
    end;

    try
      TDirectory.Delete(StagingDir, True);
    except
      on E: Exception do
        Log('WARNING: Could not remove staging folder ' + StagingDir + ': ' + E.Message);
    end;
    Exit;
  end; //while (GetTickCount64 - StartTick) < ...

  Log('ERROR: No consistent save set within ' + AUTO_WAIT_TIMEOUT.ToString + 's - no backup written. Is the server mid-save loop, or the clock skewed?');
end;

{
Runs a command line with its stdout+stderr captured through a pipe, relaying each
line to Log() (so it lands in both the console and the date-stamped log file).
Waits for the process to finish. Returns False only if the process failed to
launch; ExitCode receives the process exit code otherwise.

SteamCMD's progress is line-buffered with CR/LF, so each progress update becomes
its own logged line - exactly what we want for an unattended record.
}
function RunCapturedToLog(const ACmdLine, AWorkDir: string; out ExitCode: DWORD): Boolean;
var
  Sec: TSecurityAttributes;
  hReadOut, hWriteOut: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  LineBuf: AnsiString;
  i: Integer;

  procedure FlushLine;
  begin
    if LineBuf <> '' then
    begin
      Log(string(LineBuf));
      LineBuf := '';
    end;//if LineBuf <> '' then
  end;//procedure FlushLine;

begin
  Result := False;
  ExitCode := DWORD(-1);

  FillChar(Sec, SizeOf(Sec), 0);
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True; // child must inherit the pipe's write end

  if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then
  begin
    Log('WARNING: CreatePipe failed: ' + SysErrorMessage(GetLastError));
    Exit;
  end;//if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then

  // The parent's read end must NOT be inherited by the child.
  SetHandleInformation(hReadOut, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := hWriteOut;
  SI.hStdError := hWriteOut;

  Cmd := ACmdLine;
  UniqueString(Cmd); // CreateProcessW may modify lpCommandLine in place

  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then
  begin
    Log('WARNING: Failed to launch process: ' + SysErrorMessage(GetLastError));
    CloseHandle(hReadOut);
    CloseHandle(hWriteOut);
    Exit;
  end;//if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then

  // Close our copy of the write end so ReadFile sees EOF when the child exits.
  CloseHandle(hWriteOut);

  LineBuf := '';
  while ReadFile(hReadOut, Buffer, SizeOf(Buffer), BytesRead, nil) and (BytesRead > 0) do
    for i := 0 to Integer(BytesRead) - 1 do
      if CharInSet(Buffer[i], [#13, #10]) then
        FlushLine
      else
        LineBuf := LineBuf + Buffer[i];
  FlushLine; // anything left without a trailing newline

  WaitForSingleObject(PI.hProcess, INFINITE);
  if not GetExitCodeProcess(PI.hProcess, ExitCode) then
    ExitCode := DWORD(-1);

  CloseHandle(hReadOut);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  Result := True;
end;

{
Runs SteamCMD to update the Enshrouded dedicated server, waiting for it to
finish and capturing its output to the log. Controlled by [Update] EnableUpdate.
Non-fatal: any problem is logged and the restart still proceeds. Returns True
only if an update actually ran and SteamCMD reported success (exit code 0).
}
function UpdateServer: Boolean;
var
  CmdLine, WorkDir: string;
  ExitCode: DWORD;
begin
  Result := False;

  if not ENABLE_UPDATE then
  begin
    Log('SteamCMD update skipped (EnableUpdate=0).');
    Exit;
  end; //if not ENABLE_UPDATE then

  if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then
  begin
    Log('WARNING: SteamCMD update skipped - steamcmd.exe not found: ' + STEAMCMD_PATH);
    Exit;
  end; //if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then

  if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then
  begin
    Log('WARNING: SteamCMD update skipped - SteamAppId or InstallDir not set in ' + ConfigPath + '.');
    Exit;
  end; //if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then

  // +force_install_dir must come BEFORE +login per SteamCMD's argument ordering.
  CmdLine := Format('"%s" +force_install_dir "%s" +login anonymous +app_update %s validate +quit', [STEAMCMD_PATH,
    ExcludeTrailingPathDelimiter(STEAM_INSTALL_DIR), STEAM_APP_ID]);
  WorkDir := ExtractFilePath(STEAMCMD_PATH);

  Log('Running SteamCMD update (app ' + STEAM_APP_ID + ')...');

  if not RunCapturedToLog(CmdLine, WorkDir, ExitCode) then
    Exit; // launch failure already logged

  if ExitCode = 0 then
  begin
    Log('SteamCMD update completed successfully.');
    Result := True;
  end //if ExitCode = 0 then
  else
    Log('WARNING: SteamCMD exited with code ' + Integer(ExitCode).ToString + ' - the server may not have updated. Restart will proceed anyway.');
end;

{
Deletes every file in SERVER_LOG_DIR (recursively), leaving the folder itself in
place. Intended to run only after a successful backup. Individual delete failures
(e.g. a file still locked) are logged and skipped, not fatal. Disabled by default
for Enshrouded (ServerLogDir blank) — enable it by pointing ServerLogDir at the
folder named by "logDirectory" in enshrouded_server.json (default <install>\logs).
}
procedure PurgeServerLogs;
var
  Files: TArray<string>;
  AFile: string;
  Deleted, Failed: Integer;
begin
  if SERVER_LOG_DIR = '' then
    Exit;

  if not TDirectory.Exists(SERVER_LOG_DIR) then
  begin
    Log('Log purge skipped - folder not found: ' + SERVER_LOG_DIR);
    Exit;
  end;

  Deleted := 0;
  Failed := 0;
  try
    Files := TDirectory.GetFiles(SERVER_LOG_DIR, '*', TSearchOption.soAllDirectories);
    for AFile in Files do
    begin
      try
        TFile.Delete(AFile);
        Inc(Deleted);
      except
        on E: Exception do
        begin
          Inc(Failed);
          Log('  Could not delete ' + AFile + ': ' + E.Message);
        end;//on E: Exception do
      end;//try..except
    end;//for AFile in Files do
    Log(Format('Purged server logs in %s - %d deleted, %d skipped.',
      [SERVER_LOG_DIR, Deleted, Failed]));
  except
    on E: Exception do
      Log('WARNING: Log purge failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

procedure RestartServer;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
begin
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_SHOWMINNOACTIVE; // Start minimised; change to SW_SHOW if preferred

  if SERVER_ARGS <> '' then
    CmdLine := '"' + SERVER_EXE_PATH + '" ' + SERVER_ARGS
  else
    CmdLine := '"' + SERVER_EXE_PATH + '"';

  // CreateProcessW may modify lpCommandLine in place, so it must point to a writable, uniquely-owned buffer — otherwise it can access-violate.
  UniqueString(CmdLine);

  // WorkDir matters more than usual here: enshrouded_server.exe looks for
  // enshrouded_server.json in its working directory.
  if CreateProcess(nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  begin
    Log('Server restarted successfully (PID ' + PI.dwProcessId.ToString + ').');
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end //if CreateProcess( nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  else
    Log('ERROR: CreateProcess failed: ' + SysErrorMessage(GetLastError));
end;

var
  PID: DWORD;
  i: Integer;
  Mode: string;
begin
  Writeln('=== Enshrouded Server Restart Utility ===');
  Writeln;

  InitLogging;
  if not LoadConfig then
  begin
    ExitCode := 3;
    Exit;
  end;

  // --- Alternate mode: /autoarchive — zip a consistent savegame snapshot ---
  // Does NOT stop, restart, or otherwise touch the server. Meant to be run on
  // its own (frequent) Task Scheduler trigger, independent of the restart job.
  Mode := ParamStr(1);
  if Mode <> '' then
  begin
    if SameText(Mode, '/autoarchive') or SameText(Mode, '-autoarchive') or SameText(Mode, '--autoarchive') then
    begin
      Log('=== Auto-backup archive mode (server is not touched) ===');
      ExitCode := AutoArchive;
      Log('=== Done ===');
      Exit;
    end;//if SameText(Mode, '/autoarchive') ...

    Writeln('Unknown parameter: ' + Mode);
    Writeln('Usage:');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + '                restart cycle (shutdown, backup, update, relaunch)');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + ' /autoarchive   zip a consistent savegame snapshot to [AutoArchive] ArchiveDir while the server keeps running');
    ExitCode := 3;
    Exit;
  end;//if Mode <> '' then

  Log('=== Enshrouded Server Restart Utility started ===');

  // --- Step 0: verify the server executable exists before doing anything ---
  if not TFile.Exists(SERVER_EXE_PATH) then
  begin
    Log('ERROR: Server executable not found: ' + SERVER_EXE_PATH);
    Log('Check ExePath in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TFile.Exists(SERVER_EXE_PATH) then
  if not TDirectory.Exists(SERVER_WORK_DIR) then
  begin
    Log('ERROR: Working directory not found: ' + SERVER_WORK_DIR);
    Log('Check WorkDir in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TDirectory.Exists(SERVER_WORK_DIR) then

  // --- Step 1: find the running server ---
  Log('Looking for ' + SERVER_EXE_NAME + '...');
  PID := FindProcessByName(SERVER_EXE_NAME);
  if PID = 0 then
    Log('Server process not found. Skipping shutdown, proceeding to start.')
  else
  begin
    Log('Found server at PID ' + PID.ToString + '. Sending Ctrl+C and waiting up to ' + SHUTDOWN_TIMEOUT.ToString + 's for clean shutdown...');

    if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
    begin
      Log('WARNING: Server did not shut down cleanly. It may still be running.');
      Log('Check manually before relying on the restart.');
      ExitCode := 2;
      Exit;
    end; //if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
  end; //if..then..else PID = 0 then

  // --- Step 2: back up the savegame folder while the server is stopped ---
  // Non-fatal: a failed/skipped backup is logged but the restart still proceeds.
  // Only purge the server logs once we have a confirmed good backup.
  if BackupSavegame then
    PurgeServerLogs
  else
    Log('Skipping log purge because the backup did not complete.');

  // --- Step 3: back up the server settings (enshrouded_server.json) ---
  BackupServerSettings;

  // --- Step 4: update the server via SteamCMD (if enabled) ---
  UpdateServer;

  // --- Step 5: wait before restarting ---
  Log('Waiting ' + RESTART_DELAY.ToString + 's before restart...');
  for i := RESTART_DELAY downto 1 do
  begin
    Write(#13 + '  Restarting in ' + i.ToString + 's...  ');
    Sleep(1000);
  end; //for i := RESTART_DELAY downto 1 do
  Writeln;

  // --- Step 6: launch the server ---
  Log('Starting ' + SERVER_EXE_PATH + '...');
  RestartServer;

  Writeln;
  Log('=== Done ===');
end.
