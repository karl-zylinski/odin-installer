Windows installer for the Odin Programming Language.
- Pick which release to use, or if you want the latest nightly build
- Can download required MSVC + WinSDK files, making any kind of Visual Studio install redundant
- Copies itself into the installation folder, when run from there it acts as an updater.

## [Download latest release](https://github.com/karl-zylinski/odin-installer/releases/latest/download/odin-installer.exe)

<img width="500" alt="image" src="https://github.com/user-attachments/assets/13f1b6f9-ac8d-457b-b493-4063e9429803" />

## Release build command

This is what is used to build the releases

```bash
odin build . -o:speed -resource=odin_installer.rc -subsystem=windows
```
