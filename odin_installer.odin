// A Windows Odin installer and updater implemented using Win32 API. Downloads MSVC CRT, WinSDK and
// linker for you.

#+vet explicit-allocators
package odin_installer

import "base:intrinsics"
import "base:runtime"
import "core:compress/deflate"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "win_ex"

WM_APP_INSTALL_FINISHED :: win.WM_APP + 1
WM_APP_RELEASE_LIST_FETCHED :: win.WM_APP + 2
WM_APP_SET_PROGRESS_STATUS :: win.WM_APP + 3
WM_APP_SET_STEP :: win.WM_APP + 4
WM_APP_SET_PROGRESS :: win.WM_APP + 5
WM_APP_SET_PROGRESS_MARQUEE :: win.WM_APP + 6
WM_APP_DISABLE_CANCEL :: win.WM_APP + 7
WM_APP_NEXT :: win.WM_APP + 8
WM_APP_CANCEL :: win.WM_APP + 9
WM_APP_REBUILD :: win.WM_APP + 10
WM_APP_RELEASE_LIST_FAILED :: win.WM_APP + 11
CANCEL_NONE :: 0
CANCEL_REQUESTED :: 1
CANCEL_COMMITTED :: 2
SPINNER_TIMER :: 1
SPINNER_X :: 32
SPINNER_SIZE :: 18
PANEL_X :: 32
PANEL_Y :: 18
PANEL_WIDTH :: 456
CHECK_ROW_HEIGHT :: 22
PROGRESS_ID :: 10

LICENSE_URL :: "https://go.microsoft.com/fwlink/?LinkId=2327714"
MANIFEST_FILE :: "odin-install-manifest"
UPDATER_EXE :: "odin-updater.exe"
RELEASE_TOOLTIP :: "Picking a release is disabled until the 2026-12 release comes out."

CLIENT_WIDTH :: 520
HEADER_HEIGHT :: 44
BODY_Y :: HEADER_HEIGHT + 2
UPDATER_TEXT_HEIGHT :: 28
INSTALLER_SPINNER_Y :: 36

@(rodata)
g_page_class_names := [Page]win.LPCWSTR {
	.Installer = "OdinInstallerPage",
	.Updater = "OdinUpdaterPage",
	.Installer_Progress = "OdinInstallerProgressPage",
	.Updater_Progress = "OdinUpdaterProgressPage",
	.Installer_Finished = "OdinInstallerFinishedPage",
	.Updater_Finished = "OdinUpdaterFinishedPage",
}

g_hwnd: win.HWND
g_instance: win.HINSTANCE
g_ctx: runtime.Context
g_page: win.HWND
g_frame: Frame
g_dpi: win.UINT
g_system_dpi: win.UINT
g_font: win.HFONT
g_bold_font: win.HFONT
g_marlett_font: win.HFONT
g_italic_font: win.HFONT
g_session: win.HANDLE
g_cancel_state: int
g_child_process: uintptr
g_error: string
g_is_updater: bool
g_installer_exe_path: string
g_install_dir_buf: [win.MAX_PATH * 4]u8
g_error_buf: [2048]u8
g_page_arena: runtime.Arena
g_page_allocator: runtime.Allocator
g_native_arch: Arch
g_install_dir: string
g_nightly: bool
g_release_index: int
g_add_path: bool
g_already_in_path: bool
g_path_added: bool
g_msvc_found: bool
g_sdk_note_y: i32
g_install_sdk: bool
g_license_accepted: bool
g_installed_name: string
g_releases: []Release
g_releases_fetched: bool
g_latest_nightly: Nightly
g_tooltip: win.HWND
g_spinner_frame: int
g_current_version: string
g_client_height: i32
g_current_step: Install_Step
g_progress_status: string
g_progress_pos: int
g_progress_marquee: bool
g_finished_ok: bool
g_finished_cancelled: bool

main :: proc() {
	g_ctx = context
	g_page_allocator = runtime.arena_allocator(&g_page_arena)
	system_dir_buf: [win.MAX_PATH]u16
	win.GetSystemDirectoryW(&system_dir_buf[0], win.MAX_PATH)
	system_dir_w := cstring16(&system_dir_buf[0])
	system_dir, _ := win.wstring_to_utf8(system_dir_w, -1, context.temp_allocator)
	shell32_path := fmt.tprintf("%s\\shell32.dll", system_dir)

	common_controls_context := win.ACTCTXW {
		Size = size_of(win.ACTCTXW),
		Flags = win.ACTCTX_FLAG_RESOURCE_NAME_VALID,
		Source = win.utf8_to_wstring(shell32_path, context.temp_allocator),
		ResourceName = cstring16(win.MAKEINTRESOURCEW(124)),
	}

	common_controls_handle := win.CreateActCtxW(&common_controls_context)
	common_controls_cookie: win.ULONG_PTR
	win.ActivateActCtx(common_controls_handle, &common_controls_cookie)
	user32 := win.GetModuleHandleW("user32.dll")
	set_dpi_awareness_address := win.GetProcAddress(user32, "SetProcessDpiAwarenessContext")
	set_dpi_awareness := cast(type_of(win.SetProcessDpiAwarenessContext))set_dpi_awareness_address

	if set_dpi_awareness != nil {
		set_dpi_awareness(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	}

	icc := win.INITCOMMONCONTROLSEX {
		dwSize = size_of(win.INITCOMMONCONTROLSEX),
		dwICC = win.ICC_STANDARD_CLASSES | win.ICC_PROGRESS_CLASS | win.ICC_LINK_CLASS,
	}

	win.InitCommonControlsEx(&icc)
	win.CoInitializeEx(nil, .APARTMENTTHREADED)

	installer_exe_buf: [win.MAX_PATH]u16
	installer_exe_len := win.GetModuleFileNameW(nil, &installer_exe_buf[0], win.MAX_PATH)
	installer_exe_w := installer_exe_buf[:installer_exe_len]
	g_installer_exe_path, _ = win.utf16_to_utf8(installer_exe_w, context.allocator)
	installer_dir := g_installer_exe_path[:strings.last_index_byte(g_installer_exe_path, '\\')]

	// If we find the file with name MANIFEST_FILE next to the exe, then we assume that we are
	// currently running odin-updater.exe, which is copied into the Odin install folder after the
	// initial install.
	manifest_path := fmt.tprintf("%s\\%s", installer_dir, MANIFEST_FILE)
	manifest_path_w := win.utf8_to_wstring(manifest_path, context.temp_allocator)
	manifest_attributes := win.GetFileAttributesW(manifest_path_w)
	g_is_updater = manifest_attributes != win.INVALID_FILE_ATTRIBUTES

	CLIENT_HEIGHT :: 358
	UPDATER_CLIENT_HEIGHT :: 310
	g_client_height = g_is_updater ? UPDATER_CLIENT_HEIGHT : CLIENT_HEIGHT
	g_add_path = !g_is_updater
	g_install_sdk = false

	if !g_is_updater {
		g_msvc_found = system_has_visual_studio_and_windows_sdk()
		g_install_sdk = !g_msvc_found
	}

	g_install_dir = g_is_updater ? installer_dir : "C:\\odin"

	if g_is_updater {
		g_current_version = "unknown"

		manifest_handle := win.CreateFileW(
			manifest_path_w,
			win.GENERIC_READ,
			win.FILE_SHARE_READ,
			nil,
			win.OPEN_EXISTING,
			win.FILE_ATTRIBUTE_NORMAL,
			nil,
		)

		if manifest_handle != win.INVALID_HANDLE_VALUE {
			manifest_head: [512]u8
			manifest_read: win.DWORD
			head_size := win.DWORD(len(manifest_head))
			win.ReadFile(manifest_handle, &manifest_head[0], head_size, &manifest_read, nil)
			win.CloseHandle(manifest_handle)
			head_text := string(manifest_head[:manifest_read])
			head_lines := strings.split_lines(head_text, context.allocator)
			first_line := head_lines[0]

			if strings.has_prefix(first_line, "version\t") {
				g_current_version = strings.clone(first_line[len("version\t"):], context.allocator)
			}
		}
	}

	g_session = win_ex.WinHttpOpen(
		"odin_installer/1.0",
		win_ex.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
		nil,
		nil,
		0,
	)

	screen_dc := win.GetDC(nil)
	g_system_dpi = win.UINT(win.GetDeviceCaps(screen_dc, win_ex.LOGPIXELSY))
	win.ReleaseDC(nil, screen_dc)
	g_instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	icon_name := cstring16(win.MAKEINTRESOURCEW(1))
	small_icon_width := win.GetSystemMetrics(win.SM_CXSMICON)
	small_icon_height := win.GetSystemMetrics(win.SM_CYSMICON)

	small_icon := win.LoadImageW(
		g_instance,
		icon_name,
		win.IMAGE_ICON,
		small_icon_width,
		small_icon_height,
		0,
	)

	wc := win.WNDCLASSEXW {
		cbSize = size_of(win.WNDCLASSEXW),
		lpfnWndProc = wnd_proc,
		hInstance = g_instance,
		hCursor = win.LoadCursorA(nil, win.IDC_ARROW),
		hIcon = win.LoadIconW(g_instance, icon_name),
		hIconSm = win.HICON(small_icon),
		hbrBackground = win.HBRUSH(uintptr(win.COLOR_BTNFACE + 1)),
		lpszClassName = "OdinInstallerWindow",
	}

	win.RegisterClassExW(&wc)

	page_procs := [Page]win.WNDPROC {
		.Installer = installer_page_proc,
		.Updater = updater_page_proc,
		.Installer_Progress = installer_progress_page_proc,
		.Updater_Progress = updater_progress_page_proc,
		.Installer_Finished = installer_finished_page_proc,
		.Updater_Finished = updater_finished_page_proc,
	}

	for page_proc, page in page_procs {
		page_wc := win.WNDCLASSEXW {
			cbSize = size_of(win.WNDCLASSEXW),
			lpfnWndProc = page_proc,
			hInstance = g_instance,
			hCursor = win.LoadCursorA(nil, win.IDC_ARROW),
			hbrBackground = win.HBRUSH(uintptr(win.COLOR_BTNFACE + 1)),
			lpszClassName = g_page_class_names[page],
		}

		win.RegisterClassExW(&page_wc)
	}

	style := win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX | win.WS_CLIPCHILDREN

	g_hwnd = win.CreateWindowExW(
		win.WS_EX_CONTROLPARENT,
		wc.lpszClassName,
		g_is_updater ? "Odin Updater" : "Odin Installer",
		style,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		CLIENT_WIDTH,
		CLIENT_HEIGHT,
		nil,
		nil,
		g_instance,
		nil,
	)

	// To support older Windows versions we fetch this one at run time.
	get_dpi_for_window_address := win.GetProcAddress(user32, "GetDpiForWindow")
	get_dpi_for_window := cast(proc "system" (win.HWND) -> win.UINT)get_dpi_for_window_address

	if get_dpi_for_window != nil {
		g_dpi = get_dpi_for_window(g_hwnd)
	} else {
		g_dpi = g_system_dpi
	}

	rebuild_frame_and_fonts()
	dpi := i32(g_dpi)
	rect := win.RECT{0, 0, CLIENT_WIDTH * dpi / 96, g_client_height * dpi / 96}
	win.AdjustWindowRectEx(&rect, style, false, win.WS_EX_CONTROLPARENT)

	monitor_info := win.MONITORINFO {
		cbSize = size_of(win.MONITORINFO),
	}

	win.GetMonitorInfoW(win.MonitorFromWindow(g_hwnd, .MONITOR_DEFAULTTONEAREST), &monitor_info)
	work_area := monitor_info.rcWork
	width := rect.right - rect.left
	height := rect.bottom - rect.top
	left := work_area.left + (work_area.right - work_area.left - width) / 2
	top := work_area.top + (work_area.bottom - work_area.top - height) / 2
	win.SetWindowPos(g_hwnd, nil, left, top, width, height, win.SWP_NOZORDER)

	if g_is_updater {
		show_updater_page()
	} else {
		show_installer_page()
	}

	win.ShowWindow(g_hwnd, win.SW_SHOW)
	kernel32 := win.GetModuleHandleW("kernel32.dll")
	is_wow64_process2_address := win.GetProcAddress(kernel32, "IsWow64Process2")
	is_wow64_process2 := cast(type_of(win.IsWow64Process2))is_wow64_process2_address
	process_machine: win.USHORT
	native_machine: win.USHORT

	if is_wow64_process2 != nil {
		is_wow64_process2(win.GetCurrentProcess(), &process_machine, &native_machine)
	}

	IMAGE_FILE_MACHINE_ARM64 :: 0xAA64
	g_native_arch = native_machine == IMAGE_FILE_MACHINE_ARM64 ? .ARM64 : .AMD64
	win.CreateThread(nil, 0, releases_worker, nil, 0, nil)
	msg: win.MSG

	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		if win.IsDialogMessageW(g_hwnd, &msg) {
			continue
		}

		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

// The main wnd proc for the generic stuff.
//
// Note that each page of the installer has its own wndproc.
wnd_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case win.WM_DPICHANGED:
		g_dpi = win.UINT(win.LOWORD(u32(wparam)))
		rebuild_frame_and_fonts()
		win.SendMessageW(g_page, WM_APP_REBUILD, 0, 0)
		r := cast(^win.RECT)uintptr(lparam)

		win.SetWindowPos(
			hwnd,
			nil,
			r.left,
			r.top,
			r.right - r.left,
			r.bottom - r.top,
			win.SWP_NOZORDER | win.SWP_NOACTIVATE,
		)

		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)
		client: win.RECT
		win.GetClientRect(hwnd, &client)
		header := win.RECT{0, 0, client.right, HEADER_HEIGHT * i32(g_dpi) / 96}
		win.FillRect(hdc, &header, win.HBRUSH(win.GetStockObject(win.WHITE_BRUSH)))
		win.EndPaint(hwnd, &ps)
		return 0

	case win.WM_CTLCOLORSTATIC:
		if win.HWND(uintptr(lparam)) == g_frame.title {
			win.SetBkColor(win.HDC(uintptr(wparam)), win.RGB(255, 255, 255))
			return win.LRESULT(uintptr(win.GetStockObject(win.WHITE_BRUSH)))
		}

	case win.WM_COMMAND:
		if win.HIWORD(u32(wparam)) != win.BN_CLICKED {
			break
		}

		#partial switch Frame_Control(win.LOWORD(u32(wparam))) {
		case .Next:
			if win.IsWindowEnabled(g_frame.next) {
				win.SendMessageW(g_page, WM_APP_NEXT, 0, 0)
			}
		case .Cancel:
			win.SendMessageW(g_page, WM_APP_CANCEL, 0, 0)
		}

		return 0

	case win.WM_CLOSE:
		win.SendMessageW(g_page, WM_APP_CANCEL, 0, 0)
		return 0

	case WM_APP_INSTALL_FINISHED:
		win.SendMessageW(g_page, WM_APP_INSTALL_FINISHED, wparam, 0)
		return 0

	case WM_APP_SET_PROGRESS_STATUS:
		delete(g_progress_status, context.allocator)
		g_progress_status = strings.clone((cast(^string)uintptr(lparam))^, context.allocator)
		win.SendMessageW(g_page, WM_APP_SET_PROGRESS_STATUS, 0, 0)
		return 0

	case WM_APP_SET_STEP:
		g_current_step = Install_Step(wparam)
		win.SendMessageW(g_page, WM_APP_SET_STEP, 0, 0)
		return 0

	case WM_APP_SET_PROGRESS:
		g_progress_pos = int(wparam)

		win.SendMessageW(g_page, WM_APP_SET_PROGRESS, 0, 0)
		return 0

	case WM_APP_SET_PROGRESS_MARQUEE:
		g_progress_marquee = wparam == 1
		g_progress_pos = 0
		win.SendMessageW(g_page, WM_APP_SET_PROGRESS_MARQUEE, 0, 0)
		return 0

	case WM_APP_DISABLE_CANCEL:
		win.EnableWindow(g_frame.cancel, false)
		return 0

	case WM_APP_RELEASE_LIST_FAILED:
		win.MessageBoxW(
			hwnd,
			"The release information for Odin could not be downloaded from GitHub.\n\nCheck your internet connection and run the installer again.",
			g_is_updater ? "Odin Updater" : "Odin Installer",
			win.MB_OK | win.MB_ICONERROR,
		)

		win.DestroyWindow(hwnd)
		return 0

	case WM_APP_RELEASE_LIST_FETCHED:
		g_releases = (cast([^]Release)uintptr(lparam))[:wparam]
		g_releases_fetched = true

		if len(g_releases) == 0 {
			g_nightly = true
		}

		win.SendMessageW(g_page, WM_APP_RELEASE_LIST_FETCHED, 0, 0)
		return 0

	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

rebuild_frame_and_fonts :: proc() {
	win.DeleteObject(win.HGDIOBJ(g_font))
	win.DeleteObject(win.HGDIOBJ(g_bold_font))
	win.DeleteObject(win.HGDIOBJ(g_marlett_font))
	win.DeleteObject(win.HGDIOBJ(g_italic_font))
	win.DestroyWindow(g_frame.title)
	win.DestroyWindow(g_frame.top_line)
	win.DestroyWindow(g_frame.bottom_line)
	win.DestroyWindow(g_frame.back)
	win.DestroyWindow(g_frame.next)
	win.DestroyWindow(g_frame.cancel)

	ncm := win.NONCLIENTMETRICSW {
		cbSize = size_of(win.NONCLIENTMETRICSW),
	}

	win.SystemParametersInfoW(
		win.SPI_GETNONCLIENTMETRICS,
		size_of(win.NONCLIENTMETRICSW),
		&ncm,
		0,
	)

	font_height := ncm.lfMessageFont.lfHeight
	ncm.lfMessageFont.lfHeight = font_height * i32(g_dpi) / i32(g_system_dpi)
	g_font = win.CreateFontIndirectW(&ncm.lfMessageFont)
	italic := ncm.lfMessageFont
	italic.lfItalic = 1
	g_italic_font = win.CreateFontIndirectW(&italic)
	marlett := ncm.lfMessageFont
	marlett.lfCharSet = 2
	marlett.lfFaceName = {}
	_ = win.utf8_to_utf16(marlett.lfFaceName[:], "Marlett")

	g_marlett_font = win.CreateFontIndirectW(&marlett)
	ncm.lfMessageFont.lfWeight = win.FW_BOLD
	g_bold_font = win.CreateFontIndirectW(&ncm.lfMessageFont)
	title_font := g_bold_font
	g_frame.title = create_control(g_hwnd, 0, "STATIC", "", 0, 20, 12, 480, 20, title_font)

	g_frame.top_line = create_control(
		g_hwnd,
		0,
		"STATIC",
		"",
		win.SS_ETCHEDHORZ,
		0,
		HEADER_HEIGHT,
		CLIENT_WIDTH,
		2,
	)

	g_frame.bottom_line = create_control(
		g_hwnd,
		0,
		"STATIC",
		"",
		win.SS_ETCHEDHORZ,
		0,
		g_client_height - 50,
		CLIENT_WIDTH,
		2,
	)

	button_y := g_client_height - 36

	g_frame.back = create_control(
		g_hwnd,
		i32(Frame_Control.Back),
		"BUTTON",
		"< &Back",
		win.WS_TABSTOP | win.WS_DISABLED,
		254,
		button_y,
		75,
		23,
	)

	g_frame.next = create_control(
		g_hwnd,
		i32(Frame_Control.Next),
		"BUTTON",
		"",
		win.WS_TABSTOP | win.BS_DEFPUSHBUTTON,
		329,
		button_y,
		75,
		23,
	)

	g_frame.cancel = create_control(
		g_hwnd,
		i32(Frame_Control.Cancel),
		"BUTTON",
		"Cancel",
		win.WS_TABSTOP,
		420,
		button_y,
		75,
		23,
	)
}

releases_worker :: proc "system" (param: rawptr) -> win.DWORD {
	context = runtime.default_context()

	ODIN_RELEASES_URL :: "https://api.github.com/repos/odin-lang/Odin/releases?per_page=20"
	index, index_result := download(ODIN_RELEASES_URL, "release list")

	if index_result != .Ok {
		win.PostMessageW(g_hwnd, WM_APP_RELEASE_LIST_FAILED, 0, 0)
		free_all(context.temp_allocator)
		return 0
	}

	MIN_PUBLISHED_AT :: "2026-11-07"
	root, _ := json.parse(index, allocator = context.allocator)
	releases_json, _ := root.(json.Array)
	release_count := 0

	for release in releases_json {
		release_obj, _ := release.(json.Object)
		published_at, _ := release_obj["published_at"].(json.String)

		if published_at < MIN_PUBLISHED_AT {
			continue
		}

		assets, _ := release_obj["assets"].(json.Array)
		has_windows_zip := false

		for asset in assets {
			asset_obj, _ := asset.(json.Object)
			name, _ := asset_obj["name"].(json.String)

			if strings.contains(name, "windows") && strings.has_suffix(name, ".zip") {
				has_windows_zip = true
			}
		}

		if has_windows_zip {
			release_count += 1
		}
	}

	MAX_RELEASES :: 10
	releases := make([]Release, min(release_count, MAX_RELEASES), context.allocator)
	release_index := 0

	for release in releases_json {
		if release_index == len(releases) {
			break
		}

		release_obj, _ := release.(json.Object)
		published_at, _ := release_obj["published_at"].(json.String)

		if published_at < MIN_PUBLISHED_AT {
			continue
		}

		tag, _ := release_obj["tag_name"].(json.String)
		assets, _ := release_obj["assets"].(json.Array)
		picked: Release
		picked_rank := -1

		for asset in assets {
			asset_obj, _ := asset.(json.Object)
			name, _ := asset_obj["name"].(json.String)
			url, _ := asset_obj["browser_download_url"].(json.String)
			digest, _ := asset_obj["digest"].(json.String)
			sha256 := strings.trim_prefix(digest, "sha256:")
			is_windows_zip := strings.contains(name, "windows") && strings.has_suffix(name, ".zip")
			rank := arch_rank(name)

			if is_windows_zip && rank > picked_rank {
				picked = Release{tag, name, url, sha256}
				picked_rank = rank
			}
		}

		if picked.name != "" {
			releases[release_index] = picked
			release_index += 1
		}
	}

	ODIN_NIGHTLY_URL :: "https://f001.backblazeb2.com/file/odin-binaries/nightly.json"
	nightly_index, nightly_result := download(ODIN_NIGHTLY_URL, "nightly build list")

	if nightly_result != .Ok {
		win.PostMessageW(g_hwnd, WM_APP_RELEASE_LIST_FAILED, 0, 0)
		free_all(context.temp_allocator)
		return 0
	}

	nightly_root, _ := json.parse(nightly_index, allocator = context.allocator)
	nightly_obj, _ := nightly_root.(json.Object)
	files, _ := nightly_obj["files"].(json.Object)
	latest_nightly_date := ""
	latest_nightly_rank := -1

	for date, entries in files {
		entries_arr, _ := entries.(json.Array)

		for entry in entries_arr {
			entry_obj, _ := entry.(json.Object)
			name, _ := entry_obj["name"].(json.String)
			url, _ := entry_obj["url"].(json.String)
			sha1, _ := entry_obj["sha1"].(json.String)

			is_windows_zip := (
				strings.contains(name, "windows") &&
				strings.has_suffix(name, ".zip")
			)

			rank := arch_rank(name)
			is_better_same_date := date == latest_nightly_date && rank > latest_nightly_rank

			if is_windows_zip && (date > latest_nightly_date || is_better_same_date) {
				latest_nightly_date = date
				latest_nightly_rank = rank
				version := fmt.aprintf("nightly %s", date, allocator = context.allocator)
				g_latest_nightly.version = version
				g_latest_nightly.name = name
				g_latest_nightly.url = url
				g_latest_nightly.sha1 = sha1
				g_latest_nightly.sha1_header = ""

				if sha1 == "none" {
					g_latest_nightly.sha1 = ""
					g_latest_nightly.sha1_header = "x-bz-info-large_file_sha1"
				}
			}
		}
	}

	releases_ptr := win.LPARAM(uintptr(raw_data(releases)))
	win.PostMessageW(g_hwnd, WM_APP_RELEASE_LIST_FETCHED, uintptr(len(releases)), releases_ptr)
	free_all(context.temp_allocator)
	return 0
}

arch_rank :: proc(name: string) -> int {
	switch g_native_arch {
	case .AMD64:
		if strings.contains(name, "amd64") {
			return 2
		}

		// In case the name changes in the future, just a precaution.
		if strings.contains(name, "x64") {
			return 1
		}

	case .ARM64:
		// There are no Windows arm64 builds yet, but if one appears this may select it for people
		// with old installer exe.
		if strings.contains(name, "arm64") {
			return 2
		}

		// Windows has amd64 emulation layer on arm64 machines.
		if strings.contains(name, "amd64") || strings.contains(name, "x64") {
			return 1
		}
	}

	return 0
}

create_control :: proc(
	parent: win.HWND,
	id: i32,
	class: win.LPCWSTR,
	text: string,
	style: win.DWORD,
	x, y, w, h: i32,
	font: win.HFONT = nil,
) -> win.HWND {
	dpi := i32(g_dpi)

	hwnd := win.CreateWindowExW(
		0,
		class,
		page_temp_wstring(text),
		win.WS_CHILD | win.WS_VISIBLE | style,
		x * dpi / 96,
		y * dpi / 96,
		w * dpi / 96,
		h * dpi / 96,
		parent,
		win.HMENU(uintptr(id)),
		g_instance,
		nil,
	)

	win.SendMessageW(hwnd, win.WM_SETFONT, uintptr(font != nil ? font : g_font), 0)
	return hwnd
}

add_disabled_tooltip :: proc(page: win.HWND, control: win.HWND, text: string) {
	if g_tooltip == nil {
		g_tooltip = win.CreateWindowExW(
			win.WS_EX_TOPMOST,
			win.TOOLTIPS_CLASS,
			nil,
			win.WS_POPUP | win.TTS_ALWAYSTIP,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			page,
			nil,
			g_instance,
			nil,
		)

		max_width := 400 * i32(g_dpi) / 96
		win.SendMessageW(g_tooltip, win.TTM_SETMAXTIPWIDTH, 0, win.LPARAM(max_width))
	}

	rect: win.RECT
	win.GetWindowRect(control, &rect)
	top_left := win.POINT{rect.left, rect.top}
	bottom_right := win.POINT{rect.right, rect.bottom}
	win.ScreenToClient(page, &top_left)
	win.ScreenToClient(page, &bottom_right)

	info := win_ex.TOOLINFOW {
		cbSize = size_of(win_ex.TOOLINFOW),
		uFlags = win_ex.TTF_SUBCLASS,
		hwnd = page,
		uId = win.UINT_PTR(uintptr(control)),
		rect = win.RECT{top_left.x, top_left.y, bottom_right.x, bottom_right.y},
		lpszText = page_temp_wstring(text),
	}

	win.SendMessageW(g_tooltip, win.TTM_ADDTOOLW, 0, transmute(win.LPARAM)&info)
}

is_checked :: proc(page: win.HWND, id: i32) -> bool {
	return win.SendMessageW(win.GetDlgItem(page, id), win.BM_GETCHECK, 0, 0) == win.BST_CHECKED
}

page_tprintf :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = g_page_allocator)
}

page_temp_wstring :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s, g_page_allocator)
}

create_new_page :: proc(new_page: Page) {
	free_all(g_page_allocator)
	win.DestroyWindow(g_tooltip)
	g_tooltip = nil
	win.DestroyWindow(g_page)
	dpi := i32(g_dpi)

	g_page = win.CreateWindowExW(
		win.WS_EX_CONTROLPARENT,
		g_page_class_names[new_page],
		nil,
		win.WS_CHILD | win.WS_VISIBLE | win.WS_CLIPCHILDREN,
		0,
		BODY_Y * dpi / 96,
		CLIENT_WIDTH * dpi / 96,
		(g_client_height - 50 - BODY_Y) * dpi / 96,
		g_hwnd,
		nil,
		g_instance,
		nil,
	)
}

text_height :: proc(text: string, font: win.HFONT, width: i32) -> i32 {
	dpi := i32(g_dpi)
	hdc := win.GetDC(g_page)
	win.SelectObject(hdc, win.HGDIOBJ(font))
	rect := win.RECT{0, 0, width * dpi / 96, 0}
	format := win.DrawTextFormat(0x00000400 | 0x00000010 | 0x00002000 | 0x00000800)
	win.DrawTextW(hdc, page_temp_wstring(text), -1, &rect, format)
	win.ReleaseDC(g_page, hdc)
	return (rect.bottom * 96 + dpi - 1) / dpi
}

set_frame_state :: proc(
	title: string,
	next_text: string,
	next_enabled := false,
	cancel_enabled := false,
	cancel_visible := false,
) {
	win.SetWindowTextW(g_frame.title, page_temp_wstring(title))
	win.SetWindowTextW(g_frame.next, page_temp_wstring(next_text))
	win.EnableWindow(g_frame.next, win.BOOL(next_enabled))
	win.EnableWindow(g_frame.cancel, win.BOOL(cancel_enabled))
	win.ShowWindow(g_frame.cancel, cancel_visible ? win.SW_SHOW : win.SW_HIDE)
}

paint_spinner :: proc(hdc: win.HDC, spinner_y: i32) {
	dpi := i32(g_dpi)
	center_x := f32((SPINNER_X + SPINNER_SIZE / 2) * dpi / 96)
	center_y := f32((spinner_y + SPINNER_SIZE / 2) * dpi / 96)
	radius := f32(6 * dpi / 96)
	dot := max(2 * dpi / 96, 1)
	win.SelectObject(hdc, win.GetStockObject(win.NULL_PEN))

	for i in 0 ..< 8 {
		age := (g_spinner_frame - i + 8) % 8
		shade := u8(40 + age * 26)
		brush := win.CreateSolidBrush(win.RGB(shade, shade, shade))
		win.SelectObject(hdc, win.HGDIOBJ(brush))
		angle := f32(i) * math.TAU / 8
		x := i32(center_x + math.cos(angle) * radius)
		y := i32(center_y + math.sin(angle) * radius)
		win.Ellipse(hdc, x - dot, y - dot, x + dot + 1, y + dot + 1)
		win.SelectObject(hdc, win.GetStockObject(win.NULL_BRUSH))
		win.DeleteObject(win.HGDIOBJ(brush))
	}
}

refresh_installer_page :: proc(page: win.HWND) -> bool {
	release := win.GetDlgItem(page, i32(Installer_Page_Control.Release))
	release_list := win.GetDlgItem(page, i32(Installer_Page_Control.Release_List))
	nightly_text := win.GetDlgItem(page, i32(Installer_Page_Control.Nightly_Text))
	path_check := win.GetDlgItem(page, i32(Installer_Page_Control.Path_Check))
	license_check := win.GetDlgItem(page, i32(Installer_Page_Control.License_Check))
	has_releases := len(g_releases) > 0
	release_list_enabled := has_releases && !g_nightly
	add_path := g_add_path && !g_already_in_path
	path_state: win.WPARAM = add_path ? win.BST_CHECKED : win.BST_UNCHECKED
	win.EnableWindow(release, win.BOOL(has_releases))
	win.EnableWindow(release_list, win.BOOL(release_list_enabled))
	win.EnableWindow(nightly_text, win.BOOL(g_nightly))
	win.EnableWindow(path_check, win.BOOL(!g_already_in_path))
	win.SendMessageW(path_check, win.BM_SETCHECK, path_state, 0)
	win.EnableWindow(license_check, win.BOOL(g_install_sdk))
	can_continue := true

	if !g_releases_fetched {
		can_continue = false
	}

	if g_install_sdk && !g_license_accepted {
		can_continue = false
	}

	return can_continue
}

show_installer_page :: proc() {
	create_new_page(.Installer)
	y: i32 = 12
	create_control(g_page, 0, "STATIC", "Which version do you want to install?", 0, 32, y, 456, 20)
	y += 23

	if g_releases_fetched {
		radio_style := win.WS_TABSTOP | win.WS_GROUP | win.BS_AUTORADIOBUTTON

		release := create_control(
			g_page,
			i32(Installer_Page_Control.Release),
			"BUTTON",
			"&Release:",
			radio_style,
			44,
			y,
			135,
			20,
		)

		nightly := create_control(
			g_page,
			i32(Installer_Page_Control.Nightly),
			"BUTTON",
			"Latest ni&ghtly build:",
			win.BS_AUTORADIOBUTTON,
			44,
			y + 25,
			135,
			20,
		)

		combo_style := win.WS_TABSTOP | win.WS_GROUP | win.WS_VSCROLL | win.CBS_DROPDOWNLIST

		combo := create_control(
			g_page,
			i32(Installer_Page_Control.Release_List),
			"COMBOBOX",
			"",
			combo_style,
			183,
			y - 1,
			220,
			240,
		)

		create_control(
			g_page,
			i32(Installer_Page_Control.Nightly_Text),
			"STATIC",
			g_latest_nightly.version,
			win.SS_CENTERIMAGE,
			183,
			y + 25,
			300,
			20,
		)

		for r, i in g_releases {
			label := i == 0 ? page_tprintf("%s (latest)", r.tag) : r.tag

			win.SendMessageW(
				combo,
				win.CB_ADDSTRING,
				0,
				transmute(win.LPARAM)page_temp_wstring(label),
			)
		}

		win.SendMessageW(combo, win.CB_SETCURSEL, uintptr(g_release_index), 0)
		win.SendMessageW(g_nightly ? nightly : release, win.BM_SETCHECK, win.BST_CHECKED, 0)

		if len(g_releases) == 0 {
			add_disabled_tooltip(g_page, release, RELEASE_TOOLTIP)
			add_disabled_tooltip(g_page, combo, RELEASE_TOOLTIP)
		}
	} else {
		create_control(
			g_page,
			0,
			"STATIC",
			"Fetching latest release information.",
			0,
			56,
			y + 2,
			432,
			20,
		)

		win.SetTimer(g_page, SPINNER_TIMER, 100, nil)
	}

	y += 57
	create_control(g_page, 0, "STATIC", "Install Odin to:", 0, 32, y, 456, 20)
	edit_style := win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL

	create_control(
		g_page,
		i32(Installer_Page_Control.Dir_Edit),
		"EDIT",
		g_install_dir,
		edit_style,
		32,
		y + 20,
		370,
		23,
	)

	create_control(
		g_page,
		i32(Installer_Page_Control.Browse),
		"BUTTON",
		"B&rowse...",
		win.WS_TABSTOP,
		410,
		y + 20,
		78,
		23,
	)

	y += 54
	path_text := "Add installation directory to user's &PATH"
	check_style := win.WS_TABSTOP | win.BS_AUTOCHECKBOX

	path_check := create_control(
		g_page,
		i32(Installer_Page_Control.Path_Check),
		"BUTTON",
		path_text,
		check_style,
		32,
		y,
		456,
		20,
	)

	y += 24

	sdk_check := create_control(
		g_page,
		i32(Installer_Page_Control.SDK_Check),
		"BUTTON",
		"Download the Windows &SDK and MSVC runtime libraries",
		check_style,
		32,
		y,
		456,
		20,
	)

	g_sdk_note_y = y + 22
	y += 60
	license_check := create_control(
		g_page,
		i32(Installer_Page_Control.License_Check),
		"BUTTON",
		"I &accept the",
		check_style,
		50,
		y,
		456,
		20,
	)

	check_size: win.SIZE
	win.SendMessageW(license_check, win.BCM_GETIDEALSIZE, 0, transmute(win.LPARAM)&check_size)
	check_height := 20 * i32(g_dpi) / 96
	win.SetWindowPos(license_check, nil, 0, 0, check_size.cx, check_height, win.SWP_NOMOVE)
	hdc := win.GetDC(g_page)
	win.SelectObject(hdc, win.HGDIOBJ(g_font))
	text_metrics: win.TEXTMETRICW
	win.GetTextMetricsW(hdc, &text_metrics)
	space_size: win.SIZE
	win.GetTextExtentPoint32W(hdc, win.L(" "), 1, &space_size)
	win.ReleaseDC(g_page, hdc)

	license_link := create_control(
		g_page,
		i32(Installer_Page_Control.License_Link),
		"SysLink",
		"<a>Microsoft Visual Studio Build Tools license terms</a>",
		win.WS_TABSTOP,
		0,
		0,
		0,
		0,
	)

	link_x := 50 * i32(g_dpi) / 96 + check_size.cx + space_size.cx
	link_y := y * i32(g_dpi) / 96 + (check_height - text_metrics.tmHeight) / 2
	link_width := 488 * i32(g_dpi) / 96 - link_x
	link_height := text_metrics.tmHeight
	win.SetWindowPos(license_link, nil, link_x, link_y, link_width, link_height, win.SWP_NOZORDER)

	add_disabled_tooltip(g_page, path_check, "Already in PATH.")
	g_already_in_path = is_dir_in_path(g_install_dir)

	win.SendMessageW(
		sdk_check,
		win.BM_SETCHECK,
		g_install_sdk ? win.BST_CHECKED : win.BST_UNCHECKED,
		0,
	)

	license_state: win.WPARAM = g_license_accepted ? win.BST_CHECKED : win.BST_UNCHECKED
	win.SendMessageW(license_check, win.BM_SETCHECK, license_state, 0)
	can_continue := refresh_installer_page(g_page)

	set_frame_state(
		title = "This program installs the Odin Programming Language.",
		next_text = "&Install",
		next_enabled = can_continue,
		cancel_enabled = true,
		cancel_visible = true,
	)
}

installer_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case win.WM_COMMAND:
		id := Installer_Page_Control(win.LOWORD(u32(wparam)))
		code := win.HIWORD(u32(wparam))

		#partial switch id {
		case .Release_List:
			if code == win.CBN_SELCHANGE {
				combo := win.GetDlgItem(hwnd, i32(Installer_Page_Control.Release_List))
				g_release_index = int(win.SendMessageW(combo, win.CB_GETCURSEL, 0, 0))
				g_nightly = false

				win_ex.CheckRadioButton(
					hwnd,
					i32(Installer_Page_Control.Release),
					i32(Installer_Page_Control.Nightly),
					i32(Installer_Page_Control.Release),
				)

				can_continue := refresh_installer_page(hwnd)
				win.EnableWindow(g_frame.next, win.BOOL(can_continue))
			}
		case .Release, .Nightly, .Path_Check, .SDK_Check, .License_Check:
			if code == win.BN_CLICKED {
				path_check := win.GetDlgItem(hwnd, i32(Installer_Page_Control.Path_Check))

				if win.IsWindowEnabled(path_check) {
					g_add_path = is_checked(hwnd, i32(Installer_Page_Control.Path_Check))
				}

				g_nightly = is_checked(hwnd, i32(Installer_Page_Control.Nightly))
				g_install_sdk = is_checked(hwnd, i32(Installer_Page_Control.SDK_Check))
				g_license_accepted = is_checked(hwnd, i32(Installer_Page_Control.License_Check))
				can_continue := refresh_installer_page(hwnd)
				win.EnableWindow(g_frame.next, win.BOOL(can_continue))
			}
		case .Dir_Edit:
			if code == win.EN_CHANGE {
				dir_buf: [win.MAX_PATH]u16
				dir_edit_id := i32(Installer_Page_Control.Dir_Edit)
				win_ex.GetDlgItemTextW(hwnd, dir_edit_id, &dir_buf[0], win.MAX_PATH)
				dir := win.wstring_to_utf8(g_install_dir_buf[:], cstring16(&dir_buf[0]))
				g_install_dir = strings.trim_right(strings.trim_space(dir), "\\/")
				g_already_in_path = is_dir_in_path(g_install_dir)
				refresh_installer_page(hwnd)
			}
		case .Browse:
			if code == win.BN_CLICKED {
				display: [win.MAX_PATH]u16

				bi := win_ex.BROWSEINFOW {
					hwndOwner = g_hwnd,
					pszDisplayName = &display[0],
					lpszTitle = "Choose the folder to install Odin into:",
					ulFlags = win_ex.BIF_RETURNONLYFSDIRS | win_ex.BIF_NEWDIALOGSTYLE,
				}

				pidl := win_ex.SHBrowseForFolderW(&bi)

				if pidl != nil {
					path: [win.MAX_PATH]u16

					if win_ex.SHGetPathFromIDListW(pidl, &path[0]) {
						dir_edit_id := i32(Installer_Page_Control.Dir_Edit)
						win_ex.SetDlgItemTextW(hwnd, dir_edit_id, cstring16(&path[0]))
					}

					win.CoTaskMemFree(pidl)
				}
			}
		}

		return 0

	case win.WM_NOTIFY:
		nm := cast(^win.NMHDR)uintptr(lparam)

		if nm.code == win_ex.NM_CLICK || nm.code == win_ex.NM_RETURN {
			win.ShellExecuteW(g_hwnd, "open", LICENSE_URL, nil, nil, win.SW_SHOWNORMAL)
		}

		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)

		if !g_releases_fetched {
			paint_spinner(hdc, INSTALLER_SPINNER_Y)
		}

		dpi := i32(g_dpi)
		win.SetBkMode(hdc, .TRANSPARENT)
		win.SetTextColor(hdc, win.GetSysColor(win.COLOR_BTNTEXT))
		note_left := 50 * dpi / 96
		note_right := 488 * dpi / 96
		note_top := g_sdk_note_y * dpi / 96
		note_line_height := 16 * dpi / 96

		if g_msvc_found {
			note := []string {
				"Not needed: Already present on system. If installed anyways, then the Odin compiler will have its own set of these libraries.",
			}

			paint_text_parts(hdc, note, note_left, note_right, note_top, note_line_height)
		} else {
			note := []string {
				"This is needed for linking. These additional files will end up in the ",
				"bin\\msvc",
				" folder within the install folder. No additional environment variables are created.",
			}

			paint_text_parts(hdc, note, note_left, note_right, note_top, note_line_height)
		}

		win.EndPaint(hwnd, &ps)
		return 0

	case win.WM_TIMER:
		g_spinner_frame = (g_spinner_frame + 1) % 8

		spinner_rect := win.RECT {
			SPINNER_X * i32(g_dpi) / 96,
			INSTALLER_SPINNER_Y * i32(g_dpi) / 96,
			(SPINNER_X + SPINNER_SIZE) * i32(g_dpi) / 96,
			(INSTALLER_SPINNER_Y + SPINNER_SIZE) * i32(g_dpi) / 96,
		}

		win.InvalidateRect(hwnd, &spinner_rect, true)
		return 0

	case WM_APP_NEXT:
		if len(g_install_dir) < 3 || g_install_dir[1] != ':' {
			win.MessageBoxW(
				g_hwnd,
				"Please enter a full install path, for example C:\\odin.",
				"Odin Installer",
				win.MB_ICONWARNING,
			)

			return 0
		}

		if !is_dir_empty(g_install_dir) {
			updater_path := fmt.tprintf("%s\\%s", g_install_dir, UPDATER_EXE)
			updater_path_w := win.utf8_to_wstring(updater_path, context.temp_allocator)
			has_updater := win.GetFileAttributesW(updater_path_w) != win.INVALID_FILE_ATTRIBUTES
			message := fmt.tprintf("%s must be an empty folder.", g_install_dir)

			if has_updater {
				message = fmt.tprintf(
					"%s already contains an Odin installation. To update it, run %s\\%s.",
					g_install_dir,
					g_install_dir,
					UPDATER_EXE,
				)
			}

			win.MessageBoxW(
				g_hwnd,
				win.utf8_to_wstring(message, context.temp_allocator),
				"Odin Installer",
				win.MB_ICONWARNING,
			)

			return 0
		}

		start_install_worker()
		show_installer_progress_page()
		return 0

	case WM_APP_CANCEL:
		win.DestroyWindow(g_hwnd)
		return 0

	case WM_APP_REBUILD, WM_APP_RELEASE_LIST_FETCHED:
		show_installer_page()
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

refresh_updater_page :: proc(page: win.HWND) -> bool {
	release := win.GetDlgItem(page, i32(Updater_Page_Control.Release))
	release_list := win.GetDlgItem(page, i32(Updater_Page_Control.Release_List))
	nightly_text := win.GetDlgItem(page, i32(Updater_Page_Control.Nightly_Text))
	license_check := win.GetDlgItem(page, i32(Updater_Page_Control.License_Check))
	has_releases := len(g_releases) > 0
	release_list_enabled := has_releases && !g_nightly
	win.EnableWindow(release, win.BOOL(has_releases))
	win.EnableWindow(release_list, win.BOOL(release_list_enabled))
	win.EnableWindow(nightly_text, win.BOOL(g_nightly))
	win.EnableWindow(license_check, win.BOOL(g_install_sdk))
	can_continue := true

	if !g_releases_fetched {
		can_continue = false
	}

	if g_install_sdk && !g_license_accepted {
		can_continue = false
	}

	return can_continue
}

show_updater_page :: proc() {
	create_new_page(.Updater)
	y: i32 = 12

	create_control(
		g_page,
		0,
		"STATIC",
		page_tprintf("Current version: %s", g_current_version),
		win.SS_ENDELLIPSIS,
		32,
		y,
		456,
		20,
	)

	y += UPDATER_TEXT_HEIGHT
	create_control(g_page, 0, "STATIC", "Which version do you want to switch to?", 0, 32, y, 456, 20)
	y += 23

	if g_releases_fetched {
		radio_style := win.WS_TABSTOP | win.WS_GROUP | win.BS_AUTORADIOBUTTON

		release := create_control(
			g_page,
			i32(Updater_Page_Control.Release),
			"BUTTON",
			"&Release:",
			radio_style,
			44,
			y,
			135,
			20,
		)

		nightly := create_control(
			g_page,
			i32(Updater_Page_Control.Nightly),
			"BUTTON",
			"Latest ni&ghtly build:",
			win.BS_AUTORADIOBUTTON,
			44,
			y + 25,
			135,
			20,
		)

		combo_style := win.WS_TABSTOP | win.WS_GROUP | win.WS_VSCROLL | win.CBS_DROPDOWNLIST

		combo := create_control(
			g_page,
			i32(Updater_Page_Control.Release_List),
			"COMBOBOX",
			"",
			combo_style,
			183,
			y - 1,
			220,
			240,
		)

		create_control(
			g_page,
			i32(Updater_Page_Control.Nightly_Text),
			"STATIC",
			g_latest_nightly.version,
			win.SS_CENTERIMAGE,
			183,
			y + 25,
			300,
			20,
		)

		for r, i in g_releases {
			label := i == 0 ? page_tprintf("%s (latest)", r.tag) : r.tag

			win.SendMessageW(
				combo,
				win.CB_ADDSTRING,
				0,
				transmute(win.LPARAM)page_temp_wstring(label),
			)
		}

		win.SendMessageW(combo, win.CB_SETCURSEL, uintptr(g_release_index), 0)
		win.SendMessageW(g_nightly ? nightly : release, win.BM_SETCHECK, win.BST_CHECKED, 0)

		if len(g_releases) == 0 {
			add_disabled_tooltip(g_page, release, RELEASE_TOOLTIP)
			add_disabled_tooltip(g_page, combo, RELEASE_TOOLTIP)
		}
	} else {
		create_control(
			g_page,
			0,
			"STATIC",
			"Fetching latest release information.",
			0,
			56,
			y + 2,
			432,
			20,
		)

		win.SetTimer(g_page, SPINNER_TIMER, 100, nil)
	}

	y += 57
	check_style := win.WS_TABSTOP | win.BS_AUTOCHECKBOX

	sdk_check := create_control(
		g_page,
		i32(Updater_Page_Control.SDK_Check),
		"BUTTON",
		"Reinstall the Windows &SDK and MSVC runtime libraries",
		check_style,
		32,
		y,
		456,
		20,
	)

	y += 24
	license_check := create_control(
		g_page,
		i32(Updater_Page_Control.License_Check),
		"BUTTON",
		"I &accept the",
		check_style,
		50,
		y,
		456,
		20,
	)

	check_size: win.SIZE
	win.SendMessageW(license_check, win.BCM_GETIDEALSIZE, 0, transmute(win.LPARAM)&check_size)
	check_height := 20 * i32(g_dpi) / 96
	win.SetWindowPos(license_check, nil, 0, 0, check_size.cx, check_height, win.SWP_NOMOVE)
	hdc := win.GetDC(g_page)
	win.SelectObject(hdc, win.HGDIOBJ(g_font))
	text_metrics: win.TEXTMETRICW
	win.GetTextMetricsW(hdc, &text_metrics)
	space_size: win.SIZE
	win.GetTextExtentPoint32W(hdc, win.L(" "), 1, &space_size)
	win.ReleaseDC(g_page, hdc)

	license_link := create_control(
		g_page,
		i32(Updater_Page_Control.License_Link),
		"SysLink",
		"<a>Microsoft Visual Studio Build Tools license terms</a>",
		win.WS_TABSTOP,
		0,
		0,
		0,
		0,
	)

	link_x := 50 * i32(g_dpi) / 96 + check_size.cx + space_size.cx
	link_y := y * i32(g_dpi) / 96 + (check_height - text_metrics.tmHeight) / 2
	link_width := 488 * i32(g_dpi) / 96 - link_x
	link_height := text_metrics.tmHeight
	win.SetWindowPos(license_link, nil, link_x, link_y, link_width, link_height, win.SWP_NOZORDER)

	win.SendMessageW(
		sdk_check,
		win.BM_SETCHECK,
		g_install_sdk ? win.BST_CHECKED : win.BST_UNCHECKED,
		0,
	)

	license_state: win.WPARAM = g_license_accepted ? win.BST_CHECKED : win.BST_UNCHECKED
	win.SendMessageW(license_check, win.BM_SETCHECK, license_state, 0)

	UPDATER_NOTE_GAP :: 36
	create_control(
		g_page,
		0,
		"STATIC",
		"Note: All files from the previous Odin version will be replaced.",
		0,
		32,
		y + UPDATER_NOTE_GAP,
		456,
		20,
		g_italic_font,
	)

	can_continue := refresh_updater_page(g_page)

	set_frame_state(
		title = "This program updates the Odin Programming Language.",
		next_text = "&Update",
		next_enabled = can_continue,
		cancel_enabled = true,
		cancel_visible = true,
	)
}

updater_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx
	UPDATER_SPINNER_Y :: INSTALLER_SPINNER_Y + UPDATER_TEXT_HEIGHT

	switch msg {
	case win.WM_COMMAND:
		id := Updater_Page_Control(win.LOWORD(u32(wparam)))
		code := win.HIWORD(u32(wparam))

		#partial switch id {
		case .Release_List:
			if code == win.CBN_SELCHANGE {
				combo := win.GetDlgItem(hwnd, i32(Updater_Page_Control.Release_List))
				g_release_index = int(win.SendMessageW(combo, win.CB_GETCURSEL, 0, 0))
				g_nightly = false

				win_ex.CheckRadioButton(
					hwnd,
					i32(Updater_Page_Control.Release),
					i32(Updater_Page_Control.Nightly),
					i32(Updater_Page_Control.Release),
				)

				can_continue := refresh_updater_page(hwnd)
				win.EnableWindow(g_frame.next, win.BOOL(can_continue))
			}
		case .Release, .Nightly, .SDK_Check, .License_Check:
			if code == win.BN_CLICKED {
				g_nightly = is_checked(hwnd, i32(Updater_Page_Control.Nightly))
				g_install_sdk = is_checked(hwnd, i32(Updater_Page_Control.SDK_Check))
				g_license_accepted = is_checked(hwnd, i32(Updater_Page_Control.License_Check))
				can_continue := refresh_updater_page(hwnd)
				win.EnableWindow(g_frame.next, win.BOOL(can_continue))
			}
		}

		return 0

	case win.WM_NOTIFY:
		nm := cast(^win.NMHDR)uintptr(lparam)

		if nm.code == win_ex.NM_CLICK || nm.code == win_ex.NM_RETURN {
			win.ShellExecuteW(g_hwnd, "open", LICENSE_URL, nil, nil, win.SW_SHOWNORMAL)
		}

		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)

		if !g_releases_fetched {
			paint_spinner(hdc, UPDATER_SPINNER_Y)
		}

		win.EndPaint(hwnd, &ps)
		return 0

	case win.WM_TIMER:
		g_spinner_frame = (g_spinner_frame + 1) % 8

		spinner_rect := win.RECT {
			SPINNER_X * i32(g_dpi) / 96,
			UPDATER_SPINNER_Y * i32(g_dpi) / 96,
			(SPINNER_X + SPINNER_SIZE) * i32(g_dpi) / 96,
			(UPDATER_SPINNER_Y + SPINNER_SIZE) * i32(g_dpi) / 96,
		}

		win.InvalidateRect(hwnd, &spinner_rect, true)
		return 0

	case WM_APP_NEXT:
		start_install_worker()
		show_updater_progress_page()
		return 0

	case WM_APP_CANCEL:
		win.DestroyWindow(g_hwnd)
		return 0

	case WM_APP_REBUILD, WM_APP_RELEASE_LIST_FETCHED:
		show_updater_page()
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

start_install_worker :: proc() {
	g_path_added = false
	g_current_step = .Odin
	g_progress_status = ""
	g_progress_pos = 0
	g_progress_marquee = false
	win.CreateThread(nil, 0, install_worker, nil, 0, nil)
}

cancel_install_worker :: proc() -> bool {
	_, cancelled := intrinsics.atomic_compare_exchange_strong(
		&g_cancel_state,
		CANCEL_NONE,
		CANCEL_REQUESTED,
	)

	if cancelled {
		child := win.HANDLE(intrinsics.atomic_load(&g_child_process))

		if child != nil {
			win.TerminateProcess(child, 1)
		}
	}

	return cancelled
}

show_installer_progress_page :: proc() {
	create_new_page(.Installer_Progress)
	bar_y := progress_status_y() + 26

	progress_bar := create_control(
		g_page,
		PROGRESS_ID,
		"msctls_progress32",
		"",
		0,
		32,
		bar_y,
		456,
		20,
	)

	win.SendMessageW(progress_bar, win.PBM_SETRANGE32, 0, 1000)
	apply_progress(progress_bar)
	cancel_allowed := intrinsics.atomic_load(&g_cancel_state) != CANCEL_COMMITTED

	set_frame_state(
		title = "Please wait while Odin is being installed.",
		next_text = "&Next >",
		cancel_enabled = cancel_allowed,
		cancel_visible = true,
	)
}

installer_progress_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)
		paint_progress_panel(hdc)
		win.EndPaint(hwnd, &ps)
		return 0

	case WM_APP_SET_PROGRESS_STATUS, WM_APP_SET_STEP:
		panel_rect := win.RECT {
			PANEL_X * i32(g_dpi) / 96,
			PANEL_Y * i32(g_dpi) / 96,
			(PANEL_X + PANEL_WIDTH) * i32(g_dpi) / 96,
			(progress_status_y() + 20) * i32(g_dpi) / 96,
		}

		win.InvalidateRect(hwnd, &panel_rect, false)
		return 0

	case WM_APP_SET_PROGRESS, WM_APP_SET_PROGRESS_MARQUEE:
		apply_progress(win.GetDlgItem(hwnd, PROGRESS_ID))
		return 0

	case WM_APP_INSTALL_FINISHED:
		show_installer_finished_page(wparam == 1, false)
		return 0

	case WM_APP_CANCEL:
		if cancel_install_worker() {
			show_installer_finished_page(false, true)
		}

		return 0

	case WM_APP_REBUILD:
		show_installer_progress_page()
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

show_updater_progress_page :: proc() {
	create_new_page(.Updater_Progress)
	bar_y := progress_status_y() + 26

	progress_bar := create_control(
		g_page,
		PROGRESS_ID,
		"msctls_progress32",
		"",
		0,
		32,
		bar_y,
		456,
		20,
	)

	win.SendMessageW(progress_bar, win.PBM_SETRANGE32, 0, 1000)
	apply_progress(progress_bar)
	cancel_allowed := intrinsics.atomic_load(&g_cancel_state) != CANCEL_COMMITTED

	set_frame_state(
		title = "Please wait while Odin is being updated.",
		next_text = "&Next >",
		cancel_enabled = cancel_allowed,
		cancel_visible = true,
	)
}

updater_progress_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)
		paint_progress_panel(hdc)
		win.EndPaint(hwnd, &ps)
		return 0

	case WM_APP_SET_PROGRESS_STATUS, WM_APP_SET_STEP:
		panel_rect := win.RECT {
			PANEL_X * i32(g_dpi) / 96,
			PANEL_Y * i32(g_dpi) / 96,
			(PANEL_X + PANEL_WIDTH) * i32(g_dpi) / 96,
			(progress_status_y() + 20) * i32(g_dpi) / 96,
		}

		win.InvalidateRect(hwnd, &panel_rect, false)
		return 0

	case WM_APP_SET_PROGRESS, WM_APP_SET_PROGRESS_MARQUEE:
		apply_progress(win.GetDlgItem(hwnd, PROGRESS_ID))
		return 0

	case WM_APP_INSTALL_FINISHED:
		show_updater_finished_page(wparam == 1, false)
		return 0

	case WM_APP_CANCEL:
		if cancel_install_worker() {
			show_updater_finished_page(false, true)
		}

		return 0

	case WM_APP_REBUILD:
		show_updater_progress_page()
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

progress_status_y :: proc() -> i32 {
	rows: i32 = g_install_sdk ? 4 : 2
	checklist_bottom := PANEL_Y + rows * CHECK_ROW_HEIGHT
	page_height := g_client_height - 50 - BODY_Y
	PROGRESS_BLOCK_HEIGHT :: 46
	return checklist_bottom + (page_height - checklist_bottom - PROGRESS_BLOCK_HEIGHT) / 2
}

paint_progress_panel :: proc(hdc: win.HDC) {
	dpi := i32(g_dpi)
	status_y := progress_status_y()
	panel_width := PANEL_WIDTH * dpi / 96
	panel_height := (status_y + 20 - PANEL_Y) * dpi / 96
	mem_dc := win.CreateCompatibleDC(hdc)
	mem_bitmap := win.CreateCompatibleBitmap(hdc, panel_width, panel_height)
	win.SelectObject(mem_dc, win.HGDIOBJ(mem_bitmap))
	panel_rect := win.RECT{0, 0, panel_width, panel_height}
	win.FillRect(mem_dc, &panel_rect, win.GetSysColorBrush(win.COLOR_BTNFACE))
	win.SetBkMode(mem_dc, .TRANSPARENT)

	paint_row :: proc(dc: win.HDC, row: i32, step: Install_Step, label: string) {
		dpi := i32(g_dpi)
		row_height := CHECK_ROW_HEIGHT * dpi / 96
		icon_width := 20 * dpi / 96
		y := row * row_height
		icon_rect := win.RECT{0, y, icon_width, y + row_height}
		icon_format := win.DrawTextFormat(0x00000020 | 0x00000004 | 0x00000001)
		win.SelectObject(dc, win.HGDIOBJ(g_marlett_font))

		if step < g_current_step {
			win.SetTextColor(dc, win.RGB(0, 140, 0))
			win.DrawTextW(dc, "a", 1, &icon_rect, icon_format)
		} else if step == g_current_step {
			win.SetTextColor(dc, win.GetSysColor(win.COLOR_BTNTEXT))
			win.DrawTextW(dc, "4", 1, &icon_rect, icon_format)
		}

		label_color: i32 = step > g_current_step ? win.COLOR_GRAYTEXT : win.COLOR_BTNTEXT
		label_font := step == g_current_step ? g_bold_font : g_font
		label_rect := win.RECT{icon_width + 4 * dpi / 96, y, PANEL_WIDTH * dpi / 96, y + row_height}
		label_format := win.DrawTextFormat(0x00000020 | 0x00000004 | 0x00008000 | 0x00000800)
		win.SelectObject(dc, win.HGDIOBJ(label_font))
		win.SetTextColor(dc, win.GetSysColor(label_color))
		label_buf: [256]u16
		label_w := win.utf8_to_wstring(label_buf[:], label)
		win.DrawTextW(dc, label_w, -1, &label_rect, label_format)
	}

	finish_label := g_is_updater ? "Finishing the update" : "Finishing the installation"

	if g_install_sdk {
		paint_row(mem_dc, 0, .Odin, "Odin compiler")
		paint_row(mem_dc, 1, .MSVC, "MSVC runtime libraries")
		paint_row(mem_dc, 2, .SDK, "Windows SDK")
		paint_row(mem_dc, 3, .Finish, finish_label)
	} else {
		paint_row(mem_dc, 0, .Odin, "Odin compiler")
		paint_row(mem_dc, 1, .Finish, finish_label)
	}

	status_top := (status_y - PANEL_Y) * dpi / 96
	status_bottom := (status_y - PANEL_Y + 20) * dpi / 96
	status_rect := win.RECT{0, status_top, panel_width, status_bottom}
	text_format := win.DrawTextFormat(0x00000020 | 0x00000004 | 0x00008000 | 0x00000800)
	win.SelectObject(mem_dc, win.HGDIOBJ(g_font))
	win.SetTextColor(mem_dc, win.GetSysColor(win.COLOR_BTNTEXT))
	status_buf: [1024]u16
	status_w := win.utf8_to_wstring(status_buf[:], g_progress_status)
	win.DrawTextW(mem_dc, status_w, -1, &status_rect, text_format)

	win.BitBlt(
		hdc,
		PANEL_X * dpi / 96,
		PANEL_Y * dpi / 96,
		panel_width,
		panel_height,
		mem_dc,
		0,
		0,
		win.SRCCOPY,
	)

	win.DeleteDC(mem_dc)
	win.DeleteObject(win.HGDIOBJ(mem_bitmap))
}

apply_progress :: proc(progress_bar: win.HWND) {
	style := win.GetWindowLongW(progress_bar, win.GWL_STYLE)

	if g_progress_marquee {
		if style & win.PBS_MARQUEE == 0 {
			win.SetWindowLongW(progress_bar, win.GWL_STYLE, style | win.PBS_MARQUEE)
		}

		win.SendMessageW(progress_bar, win.PBM_SETMARQUEE, 1, 30)
	} else {
		if style & win.PBS_MARQUEE != 0 {
			win.SendMessageW(progress_bar, win.PBM_SETMARQUEE, 0, 0)
			win.SetWindowLongW(progress_bar, win.GWL_STYLE, style & ~i32(win.PBS_MARQUEE))
		}

		win.SendMessageW(progress_bar, win.PBM_SETPOS, uintptr(g_progress_pos), 0)
	}
}

show_installer_finished_page :: proc(ok: bool, cancelled: bool) {
	create_new_page(.Installer_Finished)
	g_finished_ok = ok
	g_finished_cancelled = cancelled
	title := "Something went wrong."
	text := page_tprintf("The installation did not complete.\n\n%s", g_error)

	if cancelled {
		title = "The installation was cancelled."
		text = "Odin was not installed."
	}

	if ok {
		title = "Odin was installed successfully."
	}

	if ok {
		updater_note := page_tprintf("To update Odin, run %s\\%s", g_install_dir, UPDATER_EXE)
		note_height := text_height(updater_note, g_italic_font, 456)
		note_y := g_client_height - 50 - BODY_Y - 10 - note_height

		create_control(
			g_page,
			0,
			"STATIC",
			updater_note,
			win.SS_EDITCONTROL,
			32,
			note_y,
			456,
			note_height,
			g_italic_font,
		)
	} else {
		error_height := g_client_height - 122
		create_control(g_page, 0, "STATIC", text, win.SS_EDITCONTROL, 32, 18, 456, error_height)
	}

	set_frame_state(title = title, next_text = "&Finish", next_enabled = true)
}

installer_finished_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case WM_APP_NEXT, WM_APP_CANCEL:
		win.DestroyWindow(g_hwnd)
		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)

		if g_finished_ok {
			paint_finished_items(hdc)
		}

		win.EndPaint(hwnd, &ps)
		return 0

	case WM_APP_REBUILD:
		show_installer_finished_page(g_finished_ok, g_finished_cancelled)
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

show_updater_finished_page :: proc(ok: bool, cancelled: bool) {
	create_new_page(.Updater_Finished)
	g_finished_ok = ok
	g_finished_cancelled = cancelled
	title := "Something went wrong."
	text := page_tprintf("The update did not complete.\n\n%s", g_error)

	if cancelled {
		title = "The update was cancelled."
		text = "Your Odin installation was not changed."
	}

	if ok {
		title = "Odin was updated successfully."
	}

	if !ok {
		error_height := g_client_height - 122
		create_control(g_page, 0, "STATIC", text, win.SS_EDITCONTROL, 32, 18, 456, error_height)
	}

	set_frame_state(title = title, next_text = "&Finish", next_enabled = true)
}

updater_finished_page_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ctx

	switch msg {
	case WM_APP_NEXT, WM_APP_CANCEL:
		win.DestroyWindow(g_hwnd)
		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &ps)

		if g_finished_ok {
			paint_finished_items(hdc)
		}

		win.EndPaint(hwnd, &ps)
		return 0

	case WM_APP_REBUILD:
		show_updater_finished_page(g_finished_ok, g_finished_cancelled)
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

paint_text_parts :: proc(
	hdc: win.HDC,
	parts: []string,
	left: i32,
	right: i32,
	top: i32,
	line_height: i32,
) -> i32 {
	x := left
	line_y := top

	for part, i in parts {
		part_font := i % 2 == 1 ? g_bold_font : g_font
		win.SelectObject(hdc, win.HGDIOBJ(part_font))
		part_buf: [win.MAX_PATH + 64]u16
		part_w := win.utf8_to_utf16(part_buf[:], part)
		start := 0

		for start < len(part_w) {
			end := start

			for end < len(part_w) {
				c := part_w[end]
				end += 1

				if c == ' ' || c == '\\' {
					break
				}
			}

			piece := cstring16(&part_w[start])
			piece_size: win.SIZE
			win.GetTextExtentPoint32W(hdc, piece, i32(end - start), &piece_size)

			if x + piece_size.cx > right && x > left {
				x = left
				line_y += line_height

				if part_w[start] == ' ' {
					start += 1
					continue
				}
			}

			for x + piece_size.cx > right && end - start > 1 {
				end -= 1
				win.GetTextExtentPoint32W(hdc, piece, i32(end - start), &piece_size)
			}

			win.TextOutW(hdc, x, line_y, piece, i32(end - start))
			x += piece_size.cx
			start = end
		}
	}

	return line_y
}

paint_finished_items :: proc(hdc: win.HDC) {
	paint_item :: proc(hdc: win.HDC, y: ^i32, parts: []string) {
		dpi := i32(g_dpi)
		icon_rect := win.RECT{32 * dpi / 96, y^, 52 * dpi / 96, y^ + 20 * dpi / 96}
		icon_format := win.DrawTextFormat(0x00000020 | 0x00000004 | 0x00000001)
		win.SelectObject(hdc, win.HGDIOBJ(g_marlett_font))
		win.SetTextColor(hdc, win.RGB(0, 140, 0))
		win.DrawTextW(hdc, "a", 1, &icon_rect, icon_format)
		win.SetTextColor(hdc, win.GetSysColor(win.COLOR_BTNTEXT))
		left := 58 * dpi / 96
		right := 488 * dpi / 96
		line_y := paint_text_parts(hdc, parts, left, right, y^ + 2 * dpi / 96, 18 * dpi / 96)
		y^ = line_y + 26 * dpi / 96
	}

	win.SetBkMode(hdc, .TRANSPARENT)
	y := 18 * i32(g_dpi) / 96
	paint_item(hdc, &y, {"", g_installed_name, " installed to ", g_install_dir})

	if g_install_sdk {
		sdk_dir_buf: [win.MAX_PATH * 4 + 64]u8
		sdk_dir := fmt.bprintf(sdk_dir_buf[:], "%s\\bin\\msvc", g_install_dir)
		paint_item(hdc, &y, {"Windows libraries installed to ", sdk_dir})
	}

	if g_path_added {
		paint_item(hdc, &y, {"", g_install_dir, " added to user's PATH"})
	}
}

// Parts of this is based on Mārtiņš Možeiko's portable-msvc.py:
// https://gist.github.com/mmozeiko/7f3162ec2988e81e56d5c4e22cde9977
install_worker :: proc "system" (param: rawptr) -> win.DWORD {
	context = runtime.default_context()

	ok := false
	temp_dir := fmt.tprintf("%s\\.odin-installer-tmp", g_install_dir)
	staging_odin := fmt.tprintf("%s\\odin", temp_dir)
	manifest_path := fmt.tprintf("%s\\%s", g_install_dir, MANIFEST_FILE)

	install: {
		install_dir_w := win.utf8_to_wstring(g_install_dir, context.temp_allocator)
		win.SHCreateDirectoryExW(nil, install_dir_w, nil)
		install_dir_attributes := win.GetFileAttributesW(install_dir_w)

		if install_dir_attributes == win.INVALID_FILE_ATTRIBUTES {
			set_error("Could not create install folder %s.", g_install_dir)
			break install
		}

		delete_tree(temp_dir)
		staging_odin_w := win.utf8_to_wstring(staging_odin, context.temp_allocator)

		if win.SHCreateDirectoryExW(nil, staging_odin_w, nil) != 0 {
			set_error("Could not create temporary folder %s.", staging_odin)
			break install
		}

		old_manifest_lines := make([dynamic]string, context.temp_allocator)

		manifest_handle := win.CreateFileW(
			win.utf8_to_wstring(manifest_path, context.temp_allocator),
			win.GENERIC_READ,
			win.FILE_SHARE_READ,
			nil,
			win.OPEN_EXISTING,
			win.FILE_ATTRIBUTE_NORMAL,
			nil,
		)

		if manifest_handle != win.INVALID_HANDLE_VALUE {
			manifest_size: win.LARGE_INTEGER
			win.GetFileSizeEx(manifest_handle, &manifest_size)
			manifest_data := make([]u8, int(manifest_size), context.temp_allocator)
			manifest_read: win.DWORD

			win.ReadFile(
				manifest_handle,
				raw_data(manifest_data),
				win.DWORD(len(manifest_data)),
				&manifest_read,
				nil,
			)

			win.CloseHandle(manifest_handle)
			manifest_text := string(manifest_data[:manifest_read])
			manifest_lines := strings.split_lines(manifest_text, context.temp_allocator)

			for line in manifest_lines {
				if strings.has_prefix(line, "odin\t") || strings.has_prefix(line, "msvc\t") {
					append(&old_manifest_lines, line)
				}
			}
		}

		odin_url: string
		odin_name: string
		odin_version: string
		odin_hash: string
		odin_hash_algorithm := hash.Algorithm.SHA256
		odin_hash_header := ""

		if g_nightly {
			odin_url = g_latest_nightly.url
			odin_name = g_latest_nightly.name
			odin_version = g_latest_nightly.version
			odin_hash = g_latest_nightly.sha1
			odin_hash_algorithm = .Insecure_SHA1
			odin_hash_header = g_latest_nightly.sha1_header
		} else {
			odin_url = g_releases[g_release_index].url
			odin_name = g_releases[g_release_index].name
			odin_version = g_releases[g_release_index].tag
			odin_hash = g_releases[g_release_index].sha256
		}

		if odin_url == "" {
			set_error("Could not find a Windows build of Odin.")
			break install
		}

		g_installed_name = strings.clone(odin_version, context.allocator)

		odin_zip, odin_zip_result := download(
			odin_url,
			odin_name,
			odin_hash,
			odin_hash_algorithm,
			odin_hash_header,
		)

		if odin_zip_result == .Hash_Mismatch {
			set_error("%s was downloaded, but its checksum does not match.", odin_name)
			break install
		}

		if odin_zip_result != .Ok {
			set_error("Could not download %s.", odin_name)
			break install
		}

		set_status(fmt.tprintf("Extracting %s...", odin_name))
		set_progress(0)
		odin_ok := unzip(odin_zip, staging_odin, "")
		delete(odin_zip, context.allocator)

		if !odin_ok {
			set_error("Could not extract %s.", odin_name)
			break install
		}

		odin_exe_path := fmt.tprintf("%s\\odin.exe", staging_odin)
		odin_exe_path_w := win.utf8_to_wstring(odin_exe_path, context.temp_allocator)
		odin_exe_attributes := win.GetFileAttributesW(odin_exe_path_w)

		if odin_exe_attributes == win.INVALID_FILE_ATTRIBUTES {
			set_error("odin.exe was not found after extracting the archive.")
			break install
		}

		staging_sdk := fmt.tprintf("%s\\msvc", temp_dir)

		if g_install_sdk {
			set_step(.MSVC)
			extracted_sdk := fmt.tprintf("%s\\sdk-extracted", temp_dir)
			extracted_sdk_w := win.utf8_to_wstring(extracted_sdk, context.temp_allocator)

			if win.SHCreateDirectoryExW(nil, extracted_sdk_w, nil) != 0 {
				set_error("Could not create temporary folder %s.", extracted_sdk)
				break install
			}

			VS_CHANNEL_URL :: "https://aka.ms/vs/stable/channel"
			channel, channel_result := download(VS_CHANNEL_URL, "Visual Studio channel manifest")

			if channel_result != .Ok {
				set_error("Could not download the Visual Studio channel manifest.")
				break install
			}

			channel_root, _ := json.parse(channel, allocator = context.temp_allocator)
			channel_obj, _ := channel_root.(json.Object)
			channel_items, _ := channel_obj["channelItems"].(json.Array)
			manifest_url := ""

			for item in channel_items {
				item_obj, _ := item.(json.Object)
				id, _ := item_obj["id"].(json.String)

				if id == "Microsoft.VisualStudio.Manifests.VisualStudio" {
					payloads, _ := item_obj["payloads"].(json.Array)

					if len(payloads) > 0 {
						payload_obj, _ := payloads[0].(json.Object)
						manifest_url, _ = payload_obj["url"].(json.String)
					}
				}
			}

			if manifest_url == "" {
				set_error("The Visual Studio channel manifest has no package manifest.")
				break install
			}

			manifest, manifest_result := download(manifest_url, "Visual Studio package manifest")

			if manifest_result != .Ok {
				set_error("Could not download the Visual Studio package manifest.")
				break install
			}

			set_status("Reading Visual Studio package manifest...")
			set_marquee(true)
			manifest_root, _ := json.parse(manifest, allocator = context.temp_allocator)
			delete(manifest, context.allocator)
			manifest_obj, _ := manifest_root.(json.Object)
			packages, _ := manifest_obj["packages"].(json.Array)

			preview_version := ""
			sdk_component: json.Object
			sdk_build := -1
			SDK_10_COMPONENT :: "microsoft.visualstudio.component.windows10sdk."
			SDK_11_COMPONENT :: "microsoft.visualstudio.component.windows11sdk."

			for pkg in packages {
				pkg_obj, _ := pkg.(json.Object)
				id, _ := pkg_obj["id"].(json.String)
				version, _ := pkg_obj["version"].(json.String)
				lower_id := strings.to_lower(id, context.temp_allocator)

				if lower_id == "microsoft.vc.preview.tools.hostx64.targetx64" {
					preview_version = version
				}

				is_sdk_component := (
					strings.has_prefix(lower_id, SDK_10_COMPONENT) ||
					strings.has_prefix(lower_id, SDK_11_COMPONENT)
				)

				if is_sdk_component {
					build_text := lower_id[strings.last_index_byte(lower_id, '.') + 1:]
					build, build_ok := strconv.parse_int(build_text)

					if build_ok && build > sdk_build {
						sdk_build = build
						sdk_component = pkg_obj
					}
				}
			}

			sdk_dependencies, _ := sdk_component["dependencies"].(json.Object)
			sdk_pkg_id := ""

			for dependency_id in sdk_dependencies {
				sdk_pkg_id = strings.to_lower(dependency_id, context.temp_allocator)
				break
			}

			preview_parts := strings.split_n(preview_version, ".", 3, context.temp_allocator)
			preview_major_minor := ""

			if len(preview_parts) == 3 {
				preview_major_minor = fmt.tprintf("%s.%s.", preview_parts[0], preview_parts[1])
			}

			MSVC_PREFIX :: "microsoft.vc."
			MSVC_SUFFIX :: ".tools.hostx64.targetx64.base"
			msvc_id := ""
			msvc_version := ""

			is_newer_version :: proc(version: string, than: string) -> bool {
				version_parts := strings.split(version, ".", context.temp_allocator)
				than_parts := strings.split(than, ".", context.temp_allocator)

				for i in 0 ..< max(len(version_parts), len(than_parts)) {
					version_number := 0
					than_number := 0

					if i < len(version_parts) {
						version_number, _ = strconv.parse_int(version_parts[i])
					}

					if i < len(than_parts) {
						than_number, _ = strconv.parse_int(than_parts[i])
					}

					if version_number != than_number {
						return version_number > than_number
					}
				}

				return false
			}

			for pkg in packages {
				pkg_obj, _ := pkg.(json.Object)
				id, _ := pkg_obj["id"].(json.String)
				version, _ := pkg_obj["version"].(json.String)
				lower_id := strings.to_lower(id, context.temp_allocator)

				is_msvc_tools := (
					strings.has_prefix(lower_id, MSVC_PREFIX) &&
					strings.has_suffix(lower_id, MSVC_SUFFIX) &&
					!strings.contains(lower_id, "premium")
				)

				if !is_msvc_tools {
					continue
				}

				is_preview := (
					preview_major_minor != "" &&
					strings.has_prefix(version, preview_major_minor)
				)

				if !is_preview && is_newer_version(version, msvc_version) {
					msvc_version = version
					msvc_id = id[len(MSVC_PREFIX):len(id) - len(MSVC_SUFFIX)]
				}
			}

			if msvc_id == "" || sdk_pkg_id == "" {
				set_error("Could not find MSVC or Windows SDK packages in the manifest.")
				break install
			}

			vc_package_ids := [3]string {
				fmt.tprintf("microsoft.vc.%s.crt.x64.desktop.base", msvc_id),
				fmt.tprintf("microsoft.vc.%s.crt.x64.store.base", msvc_id),
				fmt.tprintf("microsoft.vc.%s.tools.hostx64.targetx64.base", msvc_id),
			}

			vc_package_payloads: [3]json.Array
			sdk_pkg: json.Object

			for pkg in packages {
				pkg_obj, _ := pkg.(json.Object)
				id, _ := pkg_obj["id"].(json.String)
				lower_id := strings.to_lower(id, context.temp_allocator)
				payloads, _ := pkg_obj["payloads"].(json.Array)

				if lower_id == sdk_pkg_id {
					sdk_pkg = pkg_obj
				}

				language, _ := pkg_obj["language"].(json.String)
				is_english := language == "" || strings.equal_fold(language, "en-US")

				for vc_package_id, i in vc_package_ids {
					if lower_id == vc_package_id && is_english {
						vc_package_payloads[i] = payloads
					}
				}
			}

			if sdk_pkg == nil {
				set_error("Windows SDK package %s was not found in the manifest.", sdk_pkg_id)
				break install
			}

			sdk_files := make(map[string]json.Object, context.temp_allocator)
			sdk_payloads, _ := sdk_pkg["payloads"].(json.Array)

			for payload in sdk_payloads {
				payload_obj, _ := payload.(json.Object)
				file_name, _ := payload_obj["fileName"].(json.String)
				file_name, _ = strings.replace_all(file_name, "\\", "/", context.temp_allocator)

				if strings.has_prefix(file_name, "Installers/") {
					sdk_files[file_name[len("Installers/"):]] = payload_obj
				}
			}

			for vc_payloads, i in vc_package_payloads {
				if len(vc_payloads) == 0 {
					set_error("Package %s was not found.", vc_package_ids[i])
					break install
				}

				for vc_payload in vc_payloads {
					vc_payload_obj, _ := vc_payload.(json.Object)
					vsix_url, _ := vc_payload_obj["url"].(json.String)
					vsix_sha256, _ := vc_payload_obj["sha256"].(json.String)
					vsix, vsix_result := download(vsix_url, vc_package_ids[i], vsix_sha256)

					if vsix_result == .Hash_Mismatch {
						set_error(
							"%s was downloaded, but its checksum does not match.",
							vc_package_ids[i],
						)

						break install
					}

					if vsix_result != .Ok {
						set_error("Could not download %s.", vc_package_ids[i])
						break install
					}

					set_status(fmt.tprintf("Extracting %s...", vc_package_ids[i]))
					set_progress(0)
					vsix_extracted := unzip(vsix, extracted_sdk, "Contents/")
					delete(vsix, context.allocator)

					if !vsix_extracted {
						set_error("Could not extract %s.", vc_package_ids[i])
						break install
					}
				}
			}

			set_step(.SDK)
			sys_dir_buf: [win.MAX_PATH]u16
			win.GetSystemDirectoryW(&sys_dir_buf[0], win.MAX_PATH)
			sys_dir_w := cstring16(&sys_dir_buf[0])
			sys_dir, _ := win.wstring_to_utf8(sys_dir_w, -1, context.temp_allocator)
			msiexec_exe := fmt.tprintf("%s\\msiexec.exe", sys_dir)

			SDK_MSIS :: [?]string {
				"Windows SDK Desktop Libs x64-x86_en-us.msi",
				"Windows SDK for Windows Store Apps Libs-x86_en-us.msi",
				"Universal CRT Headers Libraries and Sources-x86_en-us.msi",
				"Windows SDK for Windows Store Apps Tools-x86_en-us.msi",
			}

			for msi_name in SDK_MSIS {
				msi_payload, msi_found := sdk_files[msi_name]

				if !msi_found {
					set_error("%s was not found in the Windows SDK package.", msi_name)
					break install
				}

				msi_url, _ := msi_payload["url"].(json.String)
				msi_sha256, _ := msi_payload["sha256"].(json.String)
				msi, msi_result := download(msi_url, msi_name, msi_sha256)

				if msi_result == .Hash_Mismatch {
					set_error("%s was downloaded, but its checksum does not match.", msi_name)
					break install
				}

				if msi_result != .Ok {
					set_error("Could not download %s.", msi_name)
					break install
				}

				msi_path := fmt.tprintf("%s\\%s", temp_dir, msi_name)

				if !write_file(msi_path, msi) {
					set_error("Could not write %s.", msi_path)
					break install
				}

				for i := 32; i + 4 <= len(msi); i += 1 {
					if string(msi[i:i + 4]) != ".cab" {
						continue
					}

					cab_name := string(msi[i - 32:i + 4])
					cab_payload, cab_found := sdk_files[cab_name]

					if !cab_found {
						continue
					}

					cab_path := fmt.tprintf("%s\\%s", temp_dir, cab_name)
					cab_path_w := win.utf8_to_wstring(cab_path, context.temp_allocator)
					cab_attributes := win.GetFileAttributesW(cab_path_w)

					if cab_attributes != win.INVALID_FILE_ATTRIBUTES {
						continue
					}

					cab_label := fmt.tprintf("%s (%s)", msi_name, cab_name)
					cab_url, _ := cab_payload["url"].(json.String)
					cab_sha256, _ := cab_payload["sha256"].(json.String)
					cab, cab_result := download(cab_url, cab_label, cab_sha256)

					if cab_result == .Hash_Mismatch {
						set_error("%s was downloaded, but its checksum does not match.", cab_name)
						break install
					}

					if cab_result != .Ok {
						set_error("Could not download %s.", cab_name)
						break install
					}

					if !write_file(cab_path, cab) {
						set_error("Could not write %s.", cab_path)
						break install
					}

					delete(cab, context.allocator)
				}

				delete(msi, context.allocator)

				set_status(fmt.tprintf("Extracting %s...", msi_name))
				set_marquee(true)

				msiexec_cmd := fmt.tprintf(
					"\"%s\" /a \"%s\" /quiet /qn TARGETDIR=\"%s\"",
					msiexec_exe,
					msi_path,
					extracted_sdk,
				)

				startup_info := win.STARTUPINFOW {
					cb = size_of(win.STARTUPINFOW),
				}

				process_info: win.PROCESS_INFORMATION

				created := win.CreateProcessW(
					nil,
					win.utf8_to_wstring(msiexec_cmd, context.temp_allocator),
					nil,
					nil,
					false,
					win.CREATE_NO_WINDOW,
					nil,
					nil,
					&startup_info,
					&process_info,
				)

				if !created {
					set_error("Could not start msiexec.exe.")
					break install
				}

				intrinsics.atomic_store(&g_child_process, uintptr(process_info.hProcess))

				if intrinsics.atomic_load(&g_cancel_state) == CANCEL_REQUESTED {
					win.TerminateProcess(process_info.hProcess, 1)
				}

				win.WaitForSingleObject(process_info.hProcess, win.INFINITE)
				intrinsics.atomic_store(&g_child_process, 0)
				exit_code: win.DWORD
				win.GetExitCodeProcess(process_info.hProcess, &exit_code)
				win.CloseHandle(process_info.hThread)
				win.CloseHandle(process_info.hProcess)
				set_marquee(false)

				if exit_code != 0 {
					set_error("Could not extract %s (msiexec exit code %d).", msi_name, exit_code)
					break install
				}

				extracted_msi := fmt.tprintf("%s\\%s", extracted_sdk, msi_name)
				win.DeleteFileW(win.utf8_to_wstring(extracted_msi, context.temp_allocator))
			}

			find_data: win.WIN32_FIND_DATAW
			vc_version := ""
			msvc_pattern := fmt.tprintf("%s\\VC\\Tools\\MSVC\\*", extracted_sdk)
			msvc_pattern_w := win.utf8_to_wstring(msvc_pattern, context.temp_allocator)
			find := win.FindFirstFileW(msvc_pattern_w, &find_data)

			if find != win.INVALID_HANDLE_VALUE {
				for {
					name, _ := win.wstring_to_utf8(
						cstring16(&find_data.cFileName[0]),
						-1,
						context.temp_allocator,
					)

					is_dir := (find_data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0

					if is_dir && name != "." && name != ".." && name > vc_version {
						vc_version = name
					}

					if !win.FindNextFileW(find, &find_data) {
						break
					}
				}

				win.FindClose(find)
			}

			sdk_version := ""
			sdk_pattern := fmt.tprintf("%s\\Windows Kits\\10\\Lib\\*", extracted_sdk)
			sdk_pattern_w := win.utf8_to_wstring(sdk_pattern, context.temp_allocator)
			find = win.FindFirstFileW(sdk_pattern_w, &find_data)

			if find != win.INVALID_HANDLE_VALUE {
				for {
					name, _ := win.wstring_to_utf8(
						cstring16(&find_data.cFileName[0]),
						-1,
						context.temp_allocator,
					)

					is_dir := (find_data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0

					if is_dir && name != "." && name != ".." && name > sdk_version {
						sdk_version = name
					}

					if !win.FindNextFileW(find, &find_data) {
						break
					}
				}

				win.FindClose(find)
			}

			if vc_version == "" || sdk_version == "" {
				set_error("The extracted Windows SDK or MSVC libraries are incomplete.")
				break install
			}

			vc_tools := fmt.tprintf("VC\\Tools\\MSVC\\%s", vc_version)
			vc_bin := fmt.tprintf("%s\\bin\\Hostx64\\x64", vc_tools)
			sdk_lib := fmt.tprintf("Windows Kits\\10\\Lib\\%s", sdk_version)
			sdk_bin := fmt.tprintf("Windows Kits\\10\\bin\\%s\\x64", sdk_version)

			msvc_paths := [?]string {
				fmt.tprintf("%s\\lib\\x64", vc_tools),
				fmt.tprintf("%s\\link.exe", vc_bin),
				fmt.tprintf("%s\\lib.exe", vc_bin),
				fmt.tprintf("%s\\cvtres.exe", vc_bin),
				fmt.tprintf("%s\\mspdbsrv.exe", vc_bin),
				fmt.tprintf("%s\\mspdb140.dll", vc_bin),
				fmt.tprintf("%s\\mspdbcore.dll", vc_bin),
				fmt.tprintf("%s\\msobj140.dll", vc_bin),
				fmt.tprintf("%s\\tbbmalloc.dll", vc_bin),
				fmt.tprintf("%s\\um\\x64", sdk_lib),
				fmt.tprintf("%s\\ucrt\\x64", sdk_lib),
				fmt.tprintf("%s\\rc.exe", sdk_bin),
				fmt.tprintf("%s\\rcdll.dll", sdk_bin),
				fmt.tprintf("%s\\ServicingCommon.dll", sdk_bin),
			}

			for msvc_path in msvc_paths {
				src := fmt.tprintf("%s\\%s", extracted_sdk, msvc_path)
				dst := fmt.tprintf("%s\\%s", staging_sdk, msvc_path)
				dst_parent := dst[:strings.last_index_byte(dst, '\\')]
				dst_parent_w := win.utf8_to_wstring(dst_parent, context.temp_allocator)
				win.SHCreateDirectoryExW(nil, dst_parent_w, nil)
				src_w := win.utf8_to_wstring(src, context.temp_allocator)
				dst_w := win.utf8_to_wstring(dst, context.temp_allocator)

				if !win.MoveFileExW(src_w, dst_w, 0) {
					set_error(
						"%s was not found in the extracted files.",
						src,
					)

					break install
				}
			}

			delete_tree(fmt.tprintf("%s\\%s\\lib\\x64\\store", staging_sdk, vc_tools))
			delete_tree(fmt.tprintf("%s\\%s\\lib\\x64\\uwp", staging_sdk, vc_tools))
		}

		set_step(.Finish)

		_, committed := intrinsics.atomic_compare_exchange_strong(
			&g_cancel_state,
			CANCEL_NONE,
			CANCEL_COMMITTED,
		)

		if !committed {
			break install
		}

		win.SendMessageW(g_hwnd, WM_APP_DISABLE_CANCEL, 0, 0)

		set_status("Removing files from the previous installation...")
		set_marquee(false)
		new_manifest_lines := make([dynamic]string, context.temp_allocator)

		for line, line_index in old_manifest_lines {
			if line_index % 64 == 0 {
				set_progress(line_index * 1000 / len(old_manifest_lines))
			}

			is_msvc := strings.has_prefix(line, "msvc\t")

			if is_msvc && !g_install_sdk {
				append(&new_manifest_lines, line)
				continue
			}

			path := fmt.tprintf("%s\\%s", g_install_dir, line[strings.index_byte(line, '\t') + 1:])

			if !win.DeleteFileW(win.utf8_to_wstring(path, context.temp_allocator)) {
				err := win.GetLastError()

				if err != win.ERROR_FILE_NOT_FOUND && err != win.ERROR_PATH_NOT_FOUND {
					set_error(
						"Could not remove %s. Make sure Odin is not running.",
						path,
					)

					break install
				}
			}

			parent := path

			for {
				slash := strings.last_index_byte(parent, '\\')

				if slash <= len(g_install_dir) {
					break
				}

				parent = parent[:slash]

				if !win.RemoveDirectoryW(win.utf8_to_wstring(parent, context.temp_allocator)) {
					break
				}
			}
		}

		if len(old_manifest_lines) > 0 {
			set_progress(1000)
		}

		set_status("Moving files into place...")
		set_progress(0)

		Move_Root :: struct {
			src: string,
			dst: string,
			prefix: string,
		}

		Move :: struct {
			src: string,
			dst: string,
			manifest_line: string,
		}

		moves := make([dynamic]Move, context.temp_allocator)
		sdk_dir := fmt.tprintf("%s\\bin\\msvc", g_install_dir)

		move_roots := [2]Move_Root{
			{staging_odin, g_install_dir, "odin\t"},
			{g_install_sdk ? staging_sdk : "", sdk_dir, "msvc\tbin\\msvc\\"},
		}

		for root in move_roots {
			if root.src == "" {
				continue
			}

			stack := make([dynamic]string, context.temp_allocator)
			append(&stack, root.src)

			for len(stack) > 0 {
				dir := pop(&stack)
				pattern := fmt.tprintf("%s\\*", dir)
				find_data: win.WIN32_FIND_DATAW
				pattern_w := win.utf8_to_wstring(pattern, context.temp_allocator)
				find := win.FindFirstFileW(pattern_w, &find_data)

				if find == win.INVALID_HANDLE_VALUE {
					continue
				}

				for {
					name, _ := win.wstring_to_utf8(
						cstring16(&find_data.cFileName[0]),
						-1,
						context.temp_allocator,
					)

					if name != "." && name != ".." {
						path := fmt.tprintf("%s\\%s", dir, name)
						rel := path[len(root.src) + 1:]

						if (find_data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0 {
							append(&stack, path)
						} else {
							move := Move {
								src = path,
								dst = fmt.tprintf("%s\\%s", root.dst, rel),
								manifest_line = fmt.tprintf("%s%s", root.prefix, rel),
							}

							append(&moves, move)
						}
					}

					if !win.FindNextFileW(find, &find_data) {
						break
					}
				}

				win.FindClose(find)
			}
		}

		last_parent := ""

		for move, move_index in moves {
			if move_index % 64 == 0 {
				set_progress(move_index * 1000 / len(moves))
			}

			parent := move.dst[:strings.last_index_byte(move.dst, '\\')]

			if parent != last_parent {
				parent_w := win.utf8_to_wstring(parent, context.temp_allocator)
				win.SHCreateDirectoryExW(nil, parent_w, nil)
				last_parent = parent
			}

			src_w := win.utf8_to_wstring(move.src, context.temp_allocator)
			dst_w := win.utf8_to_wstring(move.dst, context.temp_allocator)
			moved := win.MoveFileExW(src_w, dst_w, win.MOVEFILE_REPLACE_EXISTING)

			if !moved {
				set_error(
					"Could not move %s into place. Make sure Odin is not running.",
					move.dst,
				)

				break install
			}

			append(&new_manifest_lines, move.manifest_line)
		}

		set_progress(1000)

		set_status("Writing installer state...")
		manifest_builder := strings.builder_make(allocator = context.temp_allocator)
		fmt.sbprintf(&manifest_builder, "version\t%s\n", odin_version)

		for line in new_manifest_lines {
			fmt.sbprintf(&manifest_builder, "%s\n", line)
		}

		if !write_file(manifest_path, manifest_builder.buf[:]) {
			set_error("Could not write %s.", manifest_path)
			break install
		}

		updater_path := fmt.tprintf("%s\\%s", g_install_dir, UPDATER_EXE)

		if !strings.equal_fold(updater_path, g_installer_exe_path) {
			copied := win.CopyFileW(
				win.utf8_to_wstring(g_installer_exe_path, context.temp_allocator),
				win.utf8_to_wstring(updater_path, context.temp_allocator),
				false,
			)

			if !copied {
				set_error("Could not copy the installer to %s.", updater_path)
				break install
			}
		}

		if g_add_path {
			set_status("Updating the user PATH...")
			path_buf: [32768]u16
			path_size := win.DWORD(size_of(path_buf))
			current_path := ""
			path_flags: win.DWORD = win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ | win.RRF_NOEXPAND

			path_result := win.RegGetValueW(
				win.HKEY_CURRENT_USER,
				"Environment",
				"Path",
				path_flags,
				nil,
				&path_buf[0],
				&path_size,
			)

			if path_result == 0 {
				current_path, _ = win.wstring_to_utf8(
					cstring16(&path_buf[0]),
					-1,
					context.temp_allocator,
				)
			}

			if !is_dir_in_path(g_install_dir) {
				new_path := g_install_dir

				if current_path != "" {
					separator := strings.has_suffix(current_path, ";") ? "" : ";"
					new_path = fmt.tprintf("%s%s%s", current_path, separator, g_install_dir)
				}

				env_key: win.HKEY
				key_access: win.DWORD = win.KEY_SET_VALUE
				user_key := win.HKEY_CURRENT_USER
				opened := win.RegOpenKeyExW(user_key, "Environment", 0, key_access, &env_key)
				new_path_w := win.utf8_to_utf16(new_path, context.temp_allocator)
				set_result: i32 = -1

				if opened == 0 {
					set_result = win.RegSetValueExW(
						env_key,
						"Path",
						0,
						win.REG_EXPAND_SZ,
						cast(^win.BYTE)raw_data(new_path_w),
						win.DWORD((len(new_path_w) + 1) * 2),
					)

					win.RegCloseKey(env_key)
				}

				if set_result != 0 {
					set_error("Could not update the user PATH.")
					break install
				}

				g_path_added = true

				win.SendMessageTimeoutW(
					win.HWND_BROADCAST,
					win.WM_SETTINGCHANGE,
					0,
					transmute(win.LPARAM)cstring16("Environment"),
					win_ex.SMTO_ABORTIFHUNG,
					5000,
					nil,
				)
			}
		}

		ok = true
	}

	set_status("Cleaning up...")
	set_marquee(true)
	delete_tree(temp_dir)
	set_marquee(false)

	win.PostMessageW(g_hwnd, WM_APP_INSTALL_FINISHED, ok ? 1 : 0, 0)
	free_all(context.temp_allocator)
	return 0
}

set_error :: proc(format: string, args: ..any) {
	g_error = fmt.bprintf(g_error_buf[:], format, ..args)
}

set_status :: proc(text: string) {
	status_text := text
	win.SendMessageW(g_hwnd, WM_APP_SET_PROGRESS_STATUS, 0, transmute(win.LPARAM)&status_text)
}

set_step :: proc(step: Install_Step) {
	win.SendMessageW(g_hwnd, WM_APP_SET_STEP, uintptr(step), 0)
}

set_marquee :: proc(on: bool) {
	win.SendMessageW(g_hwnd, WM_APP_SET_PROGRESS_MARQUEE, on ? 1 : 0, 0)
}

set_progress :: proc(permille: int) {
	win.SendMessageW(g_hwnd, WM_APP_SET_PROGRESS, uintptr(permille), 0)
}

download :: proc(
	url: string,
	label: string,
	expected_hash := "",
	hash_algorithm := hash.Algorithm.SHA256,
	hash_header := "",
) -> (
	[]u8,
	Download_Result,
) {
	set_status(fmt.tprintf("Downloading %s...", label))
	set_marquee(false)
	escaped_url, _ := strings.replace_all(url, " ", "%20", context.temp_allocator)
	wurl := win.utf8_to_wstring(escaped_url, context.temp_allocator)

	uc := win_ex.URL_COMPONENTS {
		dwStructSize = size_of(win_ex.URL_COMPONENTS),
		dwHostNameLength = 1,
		dwUrlPathLength = 1,
		dwExtraInfoLength = 1,
	}

	if !win_ex.WinHttpCrackUrl(wurl, 0, 0, &uc) {
		return nil, .Failed
	}

	host: [512]u16
	copy(host[:511], uc.lpszHostName[:uc.dwHostNameLength])

	conn := win_ex.WinHttpConnect(g_session, cstring16(&host[0]), uc.nPort, 0)

	if conn == nil {
		return nil, .Failed
	}

	defer win_ex.WinHttpCloseHandle(conn)

	req := win_ex.WinHttpOpenRequest(
		conn,
		"GET",
		cstring16(&uc.lpszUrlPath[0]),
		nil,
		nil,
		nil,
		uc.nScheme == win_ex.INTERNET_SCHEME_HTTPS ? win_ex.WINHTTP_FLAG_SECURE : 0,
	)

	if req == nil {
		return nil, .Failed
	}

	defer win_ex.WinHttpCloseHandle(req)

	sent := win_ex.WinHttpSendRequest(req, nil, 0, nil, 0, 0, 0)

	if !sent {
		return nil, .Failed
	}

	received := win_ex.WinHttpReceiveResponse(req, nil)

	if !received {
		return nil, .Failed
	}

	status: win.DWORD
	status_size := win.DWORD(size_of(status))

	win_ex.WinHttpQueryHeaders(
		req,
		win_ex.WINHTTP_QUERY_STATUS_CODE | win_ex.WINHTTP_QUERY_FLAG_NUMBER,
		nil,
		&status,
		&status_size,
		nil,
	)

	if status != 200 {
		return nil, .Failed
	}

	hash_to_verify := expected_hash

	if hash_header != "" {
		header_buf: [256]u16
		header_size := win.DWORD(size_of(header_buf))

		header_ok := win_ex.WinHttpQueryHeaders(
			req,
			win_ex.WINHTTP_QUERY_CUSTOM,
			win.utf8_to_wstring(hash_header, context.temp_allocator),
			&header_buf[0],
			&header_size,
			nil,
		)

		if header_ok {
			header_value := header_buf[:header_size / size_of(u16)]
			hash_to_verify, _ = win.utf16_to_utf8(header_value, context.temp_allocator)
		}
	}

	total: win.DWORD
	total_size := win.DWORD(size_of(total))

	win_ex.WinHttpQueryHeaders(
		req,
		win_ex.WINHTTP_QUERY_CONTENT_LENGTH | win_ex.WINHTTP_QUERY_FLAG_NUMBER,
		nil,
		&total,
		&total_size,
		nil,
	)

	data := make([dynamic]u8, 0, int(total), context.allocator)
	buf: [65536]u8
	last_permille := -1

	for {
		if intrinsics.atomic_load(&g_cancel_state) == CANCEL_REQUESTED {
			delete(data)
			return nil, .Failed
		}

		read: win.DWORD

		if !win_ex.WinHttpReadData(req, &buf[0], len(buf), &read) {
			delete(data)
			return nil, .Failed
		}

		if read == 0 {
			break
		}

		append(&data, ..buf[:read])

		if total > 0 {
			permille := int(u64(len(data)) * 1000 / u64(total))

			if permille != last_permille {
				last_permille = permille
				set_progress(permille)
				status_buf: [512]u8

				status := fmt.bprintf(
					status_buf[:],
					"Downloading %s (%.1f of %.1f MB)...",
					label,
					f64(len(data)) / (1024 * 1024),
					f64(total) / (1024 * 1024),
				)

				set_status(status)
			}
		}
	}

	if hash_to_verify != "" {
		set_status(fmt.tprintf("Verifying %s...", label))
		digest := hash.hash_bytes(hash_algorithm, data[:], context.temp_allocator)
		digest_hex := hex.encode(digest, context.temp_allocator)

		if !strings.equal_fold(string(digest_hex), hash_to_verify) {
			delete(data)
			return nil, .Hash_Mismatch
		}
	}

	return data[:], .Ok
}

write_file :: proc(path: string, data: []u8) -> bool {
	h := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator),
		win.GENERIC_WRITE,
		0,
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)

	if h == win.INVALID_HANDLE_VALUE {
		return false
	}

	written: win.DWORD
	ok := win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, nil)
	win.CloseHandle(h)
	return bool(ok) && int(written) == len(data)
}

unzip :: proc(data: []u8, dest: string, prefix: string) -> bool {
	directory_end := -1

	for i := len(data) - 22; i >= 0; i -= 1 {
		if endian.unchecked_get_u32le(data[i:]) == 0x06054b50 {
			directory_end = i
			break
		}
	}

	if directory_end < 0 {
		return false
	}

	entry_count := int(endian.unchecked_get_u16le(data[directory_end + 10:]))
	offset := int(endian.unchecked_get_u32le(data[directory_end + 16:]))
	last_parent := ""

	for entry_index in 0 ..< entry_count {
		if intrinsics.atomic_load(&g_cancel_state) == CANCEL_REQUESTED {
			return false
		}

		if entry_index % 16 == 0 {
			set_progress(entry_index * 1000 / entry_count)
		}

		if endian.unchecked_get_u32le(data[offset:]) != 0x02014b50 {
			return false
		}

		method := endian.unchecked_get_u16le(data[offset + 10:])
		packed_size := int(endian.unchecked_get_u32le(data[offset + 20:]))
		size := int(endian.unchecked_get_u32le(data[offset + 24:]))
		name_len := int(endian.unchecked_get_u16le(data[offset + 28:]))
		extra_len := int(endian.unchecked_get_u16le(data[offset + 30:]))
		comment_len := int(endian.unchecked_get_u16le(data[offset + 32:]))
		local_offset := int(endian.unchecked_get_u32le(data[offset + 42:]))
		name := string(data[offset + 46:][:name_len])
		offset += 46 + name_len + extra_len + comment_len
		slash := strings.index_byte(name, '/')
		is_wanted_file := strings.has_prefix(name, prefix) && !strings.has_suffix(name, "/")

		if !is_wanted_file || slash < 0 {
			continue
		}

		rel, _ := strings.replace_all(name[slash + 1:], "/", "\\", context.temp_allocator)

		if strings.contains(rel, "..") {
			return false
		}

		local_name_len := int(endian.unchecked_get_u16le(data[local_offset + 26:]))
		local_extra_len := int(endian.unchecked_get_u16le(data[local_offset + 28:]))
		packed_start := local_offset + 30 + local_name_len + local_extra_len
		packed := data[packed_start:][:packed_size]
		path := fmt.tprintf("%s\\%s", dest, rel)
		parent := path[:strings.last_index_byte(path, '\\')]

		if parent != last_parent {
			parent_w := win.utf8_to_wstring(parent, context.temp_allocator)
			win.SHCreateDirectoryExW(nil, parent_w, nil)
			last_parent = parent
		}

		written := false

		if method == 0 {
			written = write_file(path, packed)
		} else if method == 8 {
			unpacked := make([dynamic]u8, context.allocator)

			inflate_err := deflate.inflate_raw_from_bytes(
				&unpacked,
				packed,
				size,
				allocator = context.allocator,
			)

			if inflate_err != nil {
				return false
			}

			written = write_file(path, unpacked[:])
			delete(unpacked)
		}

		if !written {
			return false
		}
	}

	set_progress(1000)
	return true
}

// Based on Jon Blow's "microsoft_craziness.h"
system_has_visual_studio_and_windows_sdk :: proc() -> bool {
	has_version_dir :: proc(dir_name: string) -> bool {
		wildcard_name := strings.concatenate({dir_name, "*"}, context.temp_allocator)
		find_data: win.WIN32_FIND_DATAW
		wildcard_w := win.utf8_to_wstring(wildcard_name, context.temp_allocator)
		handle := win.FindFirstFileW(wildcard_w, &find_data)

		if handle == win.INVALID_HANDLE_VALUE {
			return false
		}

		found := false

		for {
			is_dir := find_data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0
			file_name_w := cstring16(&find_data.cFileName[0])
			file_name, _ := win.wstring_to_utf8(file_name_w, -1, context.temp_allocator)
			parts := strings.split(file_name, ".", context.temp_allocator)
			is_version := is_dir && len(parts) == 4

			for part in parts {
				_, number_ok := strconv.parse_int(part)

				if !number_ok {
					is_version = false
				}
			}

			if is_version {
				found = true
			}

			if !win.FindNextFileW(handle, &find_data) {
				break
			}
		}

		win.FindClose(handle)
		return found
	}

	read_registry_string :: proc(key: win.HKEY, value_name: win.LPCWSTR) -> string {
		value_size: win.DWORD
		value_flags: win.DWORD = win.RRF_RT_REG_SZ
		size_result := win.RegGetValueW(key, nil, value_name, value_flags, nil, nil, &value_size)

		if size_result != 0 || value_size == 0 {
			return ""
		}

		value_w := make([]u16, value_size / 2 + 1, context.temp_allocator)

		value_result := win.RegGetValueW(
			key,
			nil,
			value_name,
			value_flags,
			nil,
			&value_w[0],
			&value_size,
		)

		if value_result != 0 {
			return ""
		}

		value, _ := win.wstring_to_utf8(cstring16(&value_w[0]), -1, context.temp_allocator)
		return value
	}

	file_exists :: proc(path: string) -> bool {
		attributes := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
		return attributes != win.INVALID_FILE_ATTRIBUTES
	}

	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena) 
	context.temp_allocator = context.allocator
	kits_key: win.HKEY

	kits_open_result := win.RegOpenKeyExW(
		win.HKEY_LOCAL_MACHINE,
		"SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots",
		0,
		win.KEY_QUERY_VALUE | win.KEY_WOW64_32KEY,
		&kits_key,
	)

	if kits_open_result != 0 {
		return false
	}

	windows10_root := read_registry_string(kits_key, "KitsRoot10")
	win.RegCloseKey(kits_key)

	if windows10_root == "" {
		return false
	}

	windows10_lib := strings.concatenate({windows10_root, "Lib\\"}, context.temp_allocator)
	windows10_bin := strings.concatenate({windows10_root, "bin\\"}, context.temp_allocator)
	has_lib := has_version_dir(windows10_lib)
	has_bin := has_version_dir(windows10_bin)

	if !has_lib || !has_bin {
		return false
	}

	setup_configuration_iid := win.IID {
		0x42843719,
		0xDB4C,
		0x46C2,
		{0x8E, 0x7C, 0x64, 0xF1, 0x81, 0x6E, 0xFD, 0x5B},
	}

	setup_configuration_clsid := win.CLSID {
		0x177F0C4A,
		0x1CD3,
		0x4DE7,
		{0xA3, 0x2C, 0x71, 0xDB, 0xBB, 0x9F, 0xA3, 0x6D},
	}

	config: ^win_ex.ISetupConfiguration

	create_result := win.CoCreateInstance(
		&setup_configuration_clsid,
		nil,
		win.CLSCTX_INPROC_SERVER,
		&setup_configuration_iid,
		cast(^rawptr)&config,
	)

	if create_result == 0 {
		defer config->Release()
		instances: ^win_ex.IEnumSetupInstances
		enum_result := config->EnumInstances(&instances)

		if enum_result != 0 || instances == nil {
			return false
		}

		defer instances->Release()

		for {
			found: win.ULONG
			instance: ^win_ex.ISetupInstance
			next_result := instances->Next(1, &instance, &found)

			if next_result != 0 {
				break
			}

			defer instance->Release()
			install_path_w: win.LPWSTR
			path_result := instance->GetInstallationPath(&install_path_w)

			if path_result != 0 {
				continue
			}

			install_path_c := cstring16(install_path_w)
			install_path, _ := win.wstring_to_utf8(install_path_c, -1, context.temp_allocator)
			win_ex.SysFreeString(install_path_w)
			TOOLS_FILE_SUFFIX :: "\\VC\\Auxiliary\\Build\\Microsoft.VCToolsVersion.default.txt"
			tools_parts := []string{install_path, TOOLS_FILE_SUFFIX}
			tools_filename := strings.concatenate(tools_parts, context.temp_allocator)

			tools_handle := win.CreateFileW(
				win.utf8_to_wstring(tools_filename, context.temp_allocator),
				win.GENERIC_READ,
				win.FILE_SHARE_READ,
				nil,
				win.OPEN_EXISTING,
				win.FILE_ATTRIBUTE_NORMAL,
				nil,
			)

			if tools_handle == win.INVALID_HANDLE_VALUE {
				continue
			}

			tools_buf: [256]u8
			tools_read: win.DWORD
			tools_buf_len := win.DWORD(len(tools_buf))
			win.ReadFile(tools_handle, &tools_buf[0], tools_buf_len, &tools_read, nil)
			win.CloseHandle(tools_handle)
			tools_version := strings.trim_space(string(tools_buf[:tools_read]))

			vcruntime_parts := []string {
				install_path,
				"\\VC\\Tools\\MSVC\\",
				tools_version,
				"\\lib\\x64\\vcruntime.lib",
			}

			vcruntime_file := strings.concatenate(vcruntime_parts, context.temp_allocator)

			if file_exists(vcruntime_file) {
				return true
			}
		}
	}

	vs7_key: win.HKEY

	vs7_open_result := win.RegOpenKeyExW(
		win.HKEY_LOCAL_MACHINE,
		"SOFTWARE\\Microsoft\\VisualStudio\\SxS\\VS7",
		0,
		win.KEY_QUERY_VALUE | win.KEY_WOW64_32KEY,
		&vs7_key,
	)

	if vs7_open_result != 0 {
		return false
	}

	defer win.RegCloseKey(vs7_key)
	versions := [?]win.LPCWSTR{"14.0", "13.0", "12.0", "11.0", "10.0", "9.0"}

	for version in versions {
		base_path := read_registry_string(vs7_key, version)

		if base_path == "" {
			continue
		}

		vcruntime_parts := []string{base_path, "VC\\Lib\\amd64\\vcruntime.lib"}
		vcruntime_file := strings.concatenate(vcruntime_parts, context.temp_allocator)

		if file_exists(vcruntime_file) {
			return true
		}
	}

	return false
}

is_dir_empty :: proc(dir: string) -> bool {
	pattern := fmt.tprintf("%s\\*", dir)
	find_data: win.WIN32_FIND_DATAW
	find := win.FindFirstFileW(win.utf8_to_wstring(pattern, context.temp_allocator), &find_data)

	if find == win.INVALID_HANDLE_VALUE {
		return true
	}

	empty := true

	for {
		file_name := cstring16(&find_data.cFileName[0])
		name, _ := win.wstring_to_utf8(file_name, -1, context.temp_allocator)

		if name != "." && name != ".." {
			empty = false
			break
		}

		if !win.FindNextFileW(find, &find_data) {
			break
		}
	}

	win.FindClose(find)
	return empty
}

is_dir_in_path :: proc(dir: string) -> bool {
	Dir_Identity :: struct {
		volume: win.DWORD,
		index_high: win.DWORD,
		index_low: win.DWORD,
	}

	dir_identity :: proc(path: string) -> (Dir_Identity, bool) {
		handle := win.CreateFileW(
			win.utf8_to_wstring(path, context.temp_allocator),
			0,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			nil,
			win.OPEN_EXISTING,
			win.FILE_FLAG_BACKUP_SEMANTICS,
			nil,
		)

		if handle == win.INVALID_HANDLE_VALUE {
			return {}, false
		}

		info: win.BY_HANDLE_FILE_INFORMATION
		got_info := win.GetFileInformationByHandle(handle, &info)
		win.CloseHandle(handle)
		identity := Dir_Identity{info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow}
		return identity, bool(got_info)
	}

	dir_id, dir_exists := dir_identity(dir)

	if !dir_exists {
		return false
	}

	Path_Value :: struct {
		key: win.HKEY,
		sub_key: win.LPCWSTR,
	}

	MACHINE_ENVIRONMENT_KEY :: "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"

	path_values := [2]Path_Value {
		{win.HKEY_CURRENT_USER, "Environment"},
		{win.HKEY_LOCAL_MACHINE, MACHINE_ENVIRONMENT_KEY},
	}

	path_flags: win.DWORD = win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ

	for path_value in path_values {
		path_size: win.DWORD
		key := path_value.key
		sub_key := path_value.sub_key
		win.RegGetValueW(key, sub_key, "Path", path_flags, nil, nil, &path_size)

		if path_size == 0 {
			continue
		}

		path_w := make([]u16, path_size / 2 + 1, context.temp_allocator)

		path_result := win.RegGetValueW(
			path_value.key,
			path_value.sub_key,
			"Path",
			path_flags,
			nil,
			&path_w[0],
			&path_size,
		)

		if path_result != 0 {
			continue
		}

		path, _ := win.wstring_to_utf8(cstring16(&path_w[0]), -1, context.temp_allocator)

		for entry in strings.split(path, ";", context.temp_allocator) {
			entry_path := strings.trim(entry, " \"")

			if entry_path == "" {
				continue
			}

			entry_id, entry_exists := dir_identity(entry_path)

			if entry_exists && entry_id == dir_id {
				return true
			}
		}
	}

	return false
}

delete_tree :: proc(path: string) {
	path_double_null := make([]u16, len(path) + 2, context.temp_allocator)
	_ = win.utf8_to_wstring(path_double_null, path)

	op := win.SHFILEOPSTRUCTW {
		wFunc = win.FO_DELETE,
		pFrom = cstring16(&path_double_null[0]),
		fFlags = win.FOF_NO_UI,
	}

	win.SHFileOperationW(&op)
}

Page :: enum {
	Installer,
	Updater,
	Installer_Progress,
	Updater_Progress,
	Installer_Finished,
	Updater_Finished,
}

Install_Step :: enum {
	Odin,
	MSVC,
	SDK,
	Finish,
}

Arch :: enum {
	AMD64,
	ARM64,
}

Nightly :: struct {
	version: string,
	name: string,
	url: string,
	sha1: string,
	sha1_header: string,
}

Download_Result :: enum {
	Ok,
	Failed,
	Hash_Mismatch,
}

Release :: struct {
	tag: string,
	name: string,
	url: string,
	sha256: string,
}

Frame_Control :: enum i32 {
	Next = 1,
	Cancel = 2,
	Back = 3,
}

Installer_Page_Control :: enum i32 {
	Release = 10,
	Nightly,
	Release_List,
	Nightly_Text,
	Dir_Edit,
	Browse,
	Path_Check,
	SDK_Check,
	License_Check,
	License_Link,
}

Updater_Page_Control :: enum i32 {
	Release = 10,
	Nightly,
	Release_List,
	Nightly_Text,
	SDK_Check,
	License_Check,
	License_Link,
}

Frame :: struct {
	title: win.HWND,
	top_line: win.HWND,
	bottom_line: win.HWND,
	back: win.HWND,
	next: win.HWND,
	cancel: win.HWND,
}
