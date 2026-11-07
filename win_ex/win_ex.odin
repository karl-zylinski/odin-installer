package win_ex

import win "core:sys/windows"

foreign import winhttp "system:winhttp.lib"
foreign import user32 "system:user32.lib"
foreign import shell32 "system:shell32.lib"
foreign import oleaut32 "system:oleaut32.lib"

URL_COMPONENTS :: struct {
	dwStructSize: win.DWORD,
	lpszScheme: [^]u16,
	dwSchemeLength: win.DWORD,
	nScheme: i32,
	lpszHostName: [^]u16,
	dwHostNameLength: win.DWORD,
	nPort: u16,
	lpszUserName: [^]u16,
	dwUserNameLength: win.DWORD,
	lpszPassword: [^]u16,
	dwPasswordLength: win.DWORD,
	lpszUrlPath: [^]u16,
	dwUrlPathLength: win.DWORD,
	lpszExtraInfo: [^]u16,
	dwExtraInfoLength: win.DWORD,
}

BROWSEINFOW :: struct {
	hwndOwner: win.HWND,
	pidlRoot: rawptr,
	pszDisplayName: [^]u16,
	lpszTitle: win.LPCWSTR,
	ulFlags: win.UINT,
	lpfn: rawptr,
	lParam: win.LPARAM,
	iImage: i32,
}

TOOLINFOW :: struct {
	cbSize: win.UINT,
	uFlags: win.UINT,
	hwnd: win.HWND,
	uId: win.UINT_PTR,
	rect: win.RECT,
	hinst: win.HINSTANCE,
	lpszText: win.wstring,
	lParam: win.LPARAM,
	lpReserved: rawptr,
}

@(default_calling_convention = "system")
foreign winhttp {
	WinHttpOpen :: proc(
		agent: win.LPCWSTR,
		access_type: win.DWORD,
		proxy: win.LPCWSTR,
		bypass: win.LPCWSTR,
		flags: win.DWORD,
	) -> win.HANDLE ---

	WinHttpCrackUrl :: proc(
		url: win.LPCWSTR,
		url_len: win.DWORD,
		flags: win.DWORD,
		components: ^URL_COMPONENTS,
	) -> win.BOOL ---

	WinHttpConnect :: proc(
		session: win.HANDLE,
		server: win.LPCWSTR,
		port: u16,
		reserved: win.DWORD,
	) -> win.HANDLE ---

	WinHttpOpenRequest :: proc(
		connect: win.HANDLE,
		verb: win.LPCWSTR,
		object: win.LPCWSTR,
		version: win.LPCWSTR,
		referrer: win.LPCWSTR,
		accept_types: rawptr,
		flags: win.DWORD,
	) -> win.HANDLE ---

	WinHttpSendRequest :: proc(
		request: win.HANDLE,
		headers: win.LPCWSTR,
		headers_len: win.DWORD,
		optional: rawptr,
		optional_len: win.DWORD,
		total_len: win.DWORD,
		ctx: uintptr,
	) -> win.BOOL ---

	WinHttpReceiveResponse :: proc(request: win.HANDLE, reserved: rawptr) -> win.BOOL ---

	WinHttpQueryHeaders :: proc(
		request: win.HANDLE,
		info_level: win.DWORD,
		name: win.LPCWSTR,
		buffer: rawptr,
		buffer_len: ^win.DWORD,
		index: ^win.DWORD,
	) -> win.BOOL ---

	WinHttpReadData :: proc(
		request: win.HANDLE,
		buffer: rawptr,
		to_read: win.DWORD,
		read: ^win.DWORD,
	) -> win.BOOL ---

	WinHttpCloseHandle :: proc(h: win.HANDLE) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign user32 {
	CheckRadioButton :: proc(
		dlg: win.HWND,
		first_id: i32,
		last_id: i32,
		check_id: i32,
	) -> win.BOOL ---

	GetDlgItemTextW :: proc(dlg: win.HWND, id: i32, text: [^]u16, max_count: i32) -> win.UINT ---
	SetDlgItemTextW :: proc(dlg: win.HWND, id: i32, text: win.LPCWSTR) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign shell32 {
	SHBrowseForFolderW :: proc(bi: ^BROWSEINFOW) -> rawptr ---
	SHGetPathFromIDListW :: proc(pidl: rawptr, path: [^]u16) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign oleaut32 {
	SysFreeString :: proc(str: win.LPWSTR) ---
}

ISetupInstance :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^ISetupInstance_VTable,
}

ISetupInstance_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	GetInstanceId: proc "system" (this: ^ISetupInstance, id: ^win.LPWSTR) -> win.HRESULT,
	GetInstallDate: proc "system" (this: ^ISetupInstance, date: ^win.FILETIME) -> win.HRESULT,
	GetInstallationName: proc "system" (this: ^ISetupInstance, name: ^win.LPWSTR) -> win.HRESULT,
	GetInstallationPath: proc "system" (this: ^ISetupInstance, path: ^win.LPWSTR) -> win.HRESULT,
	GetInstallationVersion: proc "system" (
		this: ^ISetupInstance,
		version: ^win.LPWSTR,
	) -> win.HRESULT,
	GetDisplayName: proc "system" (
		this: ^ISetupInstance,
		lcid: win.LCID,
		name: ^win.LPWSTR,
	) -> win.HRESULT,
	GetDescription: proc "system" (
		this: ^ISetupInstance,
		lcid: win.LCID,
		description: ^win.LPWSTR,
	) -> win.HRESULT,
	ResolvePath: proc "system" (
		this: ^ISetupInstance,
		relative_path: win.LPCWSTR,
		absolute_path: ^win.LPWSTR,
	) -> win.HRESULT,
}

IEnumSetupInstances :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^IEnumSetupInstances_VTable,
}

IEnumSetupInstances_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	Next: proc "system" (
		this: ^IEnumSetupInstances,
		count: win.ULONG,
		instances: ^^ISetupInstance,
		fetched: ^win.ULONG,
	) -> win.HRESULT,
	Skip: proc "system" (this: ^IEnumSetupInstances, count: win.ULONG) -> win.HRESULT,
	Reset: proc "system" (this: ^IEnumSetupInstances) -> win.HRESULT,
	Clone: proc "system" (
		this: ^IEnumSetupInstances,
		clone: ^^IEnumSetupInstances,
	) -> win.HRESULT,
}

ISetupConfiguration :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable: ^ISetupConfiguration_VTable,
}

ISetupConfiguration_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	EnumInstances: proc "system" (
		this: ^ISetupConfiguration,
		instances: ^^IEnumSetupInstances,
	) -> win.HRESULT,
	GetInstanceForCurrentProcess: proc "system" (
		this: ^ISetupConfiguration,
		instance: ^^ISetupInstance,
	) -> win.HRESULT,
	GetInstanceForPath: proc "system" (
		this: ^ISetupConfiguration,
		path: win.LPCWSTR,
		instance: ^^ISetupInstance,
	) -> win.HRESULT,
}

WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
WINHTTP_FLAG_SECURE :: 0x00800000
INTERNET_SCHEME_HTTPS :: 2
WINHTTP_QUERY_CONTENT_LENGTH :: 5
WINHTTP_QUERY_STATUS_CODE :: 19
WINHTTP_QUERY_FLAG_NUMBER :: 0x20000000
BIF_RETURNONLYFSDIRS :: 0x0001
BIF_NEWDIALOGSTYLE :: 0x0040
SMTO_ABORTIFHUNG :: 0x0002
LOGPIXELSY :: 90
NM_CLICK :: ~u32(1)
NM_RETURN :: ~u32(3)
TTF_SUBCLASS :: 0x0010
