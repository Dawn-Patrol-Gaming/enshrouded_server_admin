# Building with Free Pascal / Lazarus

The official project is written for **Delphi** and that's what the maintainer
builds and ships. The code is, however, plain Win32 API + RTL, so it can be made
to compile under **Free Pascal (FPC) / Lazarus** with a modest amount of work.

This is **not maintained or tested** by the project — it's a pointer for anyone
who'd rather build with FPC. The Delphi source is intentionally kept free of
`{$IFDEF FPC}` clutter, so you'll be making local edits.

> Tip: do this on a fork/branch and keep your FPC changes there.

---

## What ports unchanged

These need no changes — FPC supports them directly (use `{$mode Delphi}`):

- All Win32 calls: `AttachConsole`, `FreeConsole`, `GenerateConsoleCtrlEvent`,
  `SetConsoleCtrlHandler`, `CreateProcess`, `CreatePipe`, `ReadFile`,
  `WaitForSingleObject`, `GetExitCodeProcess`, the toolhelp32 snapshot calls, etc.
- `TCriticalSection` (`syncobjs`), `TIniFile` (`IniFiles`), `TFileStream` (`Classes`).
- `TTextRec(Output).Handle`, `CharInSet`, integer `.ToString`,
  `string.StartsWith` / `.Substring` (recent FPC, Delphi mode).

## Unit names

FPC uses non-dotted unit names. In the `uses` clause, map:

| Delphi unit | FPC unit |
|---|---|
| `Winapi.Windows` | `Windows` |
| `Winapi.TlHelp32` | `tlhelp32` |
| `System.SysUtils` | `SysUtils` |
| `System.DateUtils` | `DateUtils` |
| `System.Classes` | `Classes` |
| `System.IniFiles` | `IniFiles` |
| `System.SyncObjs` | `syncobjs` |
| `System.IOUtils` | *(remove — see below)* |
| `System.Zip` | `zipper` *(see below)* |

(Or enable namespaced unit aliasing in the project options instead of renaming.)

---

## The two real changes

### 1. Replace `System.IOUtils` calls

FPC's `IOUtils` is incomplete. Swap the `TPath` / `TFile` / `TDirectory` calls
for standard RTL equivalents (add `fileutil` to `uses` for `FindAllFiles`):

| Delphi (`System.IOUtils`) | FPC replacement |
|---|---|
| `TFile.Exists(p)` | `FileExists(p)` |
| `TDirectory.Exists(p)` | `DirectoryExists(p)` |
| `TDirectory.CreateDirectory(p)` | `ForceDirectories(p)` |
| `TDirectory.GetFiles(d, mask, soAllDirectories)` | `FindAllFiles(d, mask, True)` (returns a `TStringList`) |
| `TDirectory.GetFiles(d, mask, soTopDirectoryOnly)` | `FindAllFiles(d, mask, False)` |
| `TPath.Combine(a, b)` | `ConcatPaths([a, b])` or `IncludeTrailingPathDelimiter(a)+b` |
| `TPath.ChangeExtension(p, '.ini')` | `ChangeFileExt(p, '.ini')` |
| `TFile.Delete(p)` | `DeleteFile(p)` |

`FindAllFiles` returns a `TStringList` rather than a `TArray<string>`, so adjust
the loops in `ZipFolder` and `PurgeServerLogs` to iterate the list (and free it).
Note `ZipFolder` here takes a `Recurse: Boolean` parameter (the settings backup
of `enshrouded_server.json` is non-recursive) — map it straight to
`FindAllFiles`'s third argument.

### 2. Rewrite `ZipFolder` with the `zipper` unit

`System.Zip.TZipFile` has no FPC equivalent. Use `zipper`:

```pascal
uses zipper;

// inside ZipFolder, instead of TZipFile:
var
  Zip: TZipper;
  // ...
begin
  Zip := TZipper.Create;
  try
    Zip.FileName := ZipPath;
    for SrcFile in Files do        // Files = a TStringList from FindAllFiles
    begin
      RelName := ...;              // same relative-path logic as before
      Zip.Entries.AddFileEntry(SrcFile, RelName);
    end;
    Zip.ZipAllFiles;
  finally
    Zip.Free;
  end;
end;
```

---

## Manifest / elevation

The Delphi build embeds a `requireAdministrator` manifest (the tool must run
elevated — see the main README). In Lazarus, set this in
**Project → Project Options → Application**:

- check **"Use manifest resource"**
- set **Execution Level = requireAdministrator** (or `highestAvailable`)

Without this, attaching to the elevated server's console fails with
*Access is denied*.

---

## Summary

A competent FPC developer can usually get this building in well under an hour:
the IOUtils swaps and the `zipper` rewrite are the only real work; everything
else — the entire graceful-shutdown core — compiles as-is.

If you produce a clean cross-compiling fork, feel free to link it in an issue so
others can find it.
