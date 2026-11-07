Windows installer for the Odin Programming Language that also downloads required MSVC/WinSDK files. Upon successful install, it copies itself into the Odin folder and can then be used as an Odin updater.

## [Download latest release](https://github.com/karl-zylinski/odin-installer/releases/latest/download/odin-installer.exe)

<img width="500" alt="image" src="https://github.com/user-attachments/assets/13f1b6f9-ac8d-457b-b493-4063e9429803" />

## Release build command

This is what is used to build the releases

```bash
odin build . -o:speed -resource=odin_installer.rc -subsystem=windows
```
