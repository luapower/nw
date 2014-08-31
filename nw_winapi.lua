
--native widgets - winapi backend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local bitmap = require'bitmap' --for clipboard
local winapi = require'winapi'
require'winapi.spi'
require'winapi.sysinfo'
require'winapi.systemmetrics'
require'winapi.windowclass'
require'winapi.gdi'
require'winapi.bitmap'
require'winapi.icon'

local nw = {name = 'winapi'}

--helpers --------------------------------------------------------------------

local function unpack_rect(rect)
	return rect.x, rect.y, rect.w, rect.h
end

local function pack_rect(rect, x, y, w, h)
	rect = rect or winapi.RECT()
	rect.x, rect.y, rect.w, rect.h = x, y, w, h
	return rect
end

--os version -----------------------------------------------------------------

function nw:os(ver)
	local vinfo = winapi.GetVersionEx()
	return string.format('Windows %d.%d.SP%d.%d',
		vinfo.dwMajorVersion, vinfo.dwMinorVersion,
		vinfo.wServicePackMajor, vinfo.wServicePackMinor)
end

nw.min_os = 'Windows 5.1' --Windows XP+

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

function app:new(frontend)

	self = glue.inherit({frontend = frontend}, self)

	--enable WM_INPUT for keyboard events
	local rid = winapi.types.RAWINPUTDEVICE()
	rid.dwFlags = 0
	rid.usUsagePage = 1 --generic desktop controls
	rid.usUsage     = 6 --keyboard
	winapi.RegisterRawInputDevices(rid, 1, ffi.sizeof(rid))

	self._active = false

	return self
end

--message loop ---------------------------------------------------------------

function app:run()
	self:_init_activate()
	winapi.MessageLoop(function(msg)
		--print(winapi.findname('WM_', msg.message))
	end)
end

function app:stop()
	winapi.PostQuitMessage()
end

--time -----------------------------------------------------------------------

require'winapi.time'

function app:time()
	return winapi.QueryPerformanceCounter().QuadPart
end

local qpf
function app:timediff(start_time, end_time)
	qpf = qpf or tonumber(winapi.QueryPerformanceFrequency().QuadPart)
	local interval = end_time - start_time
	return tonumber(interval * 1000) / qpf --milliseconds
end

--timers ---------------------------------------------------------------------

local timer_cb
local timers = {}

function app:runevery(seconds, func)
	timer_cb = timer_cb or ffi.cast('TIMERPROC', function(hwnd, wm_timer, id, ellapsed_ms)
		local func = timers[id]
		if not func then return end
		if func() == false then
			timers[id] = nil
			winapi.KillTimer(nil, id)
		end
	end)
	local id = winapi.SetTimer(nil, 0, seconds * 1000, timer_cb)
	timers[id] = func
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local Window = winapi.subclass({}, winapi.Window)

local win_map = {} --win->window, for app:active_window()

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local framed = t.frame == 'normal' or t.frame == 'toolbox'
	self._layered = t.frame == 'none-transparent'

	self.win = Window{
		--state
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		min_cw = t.min_cw,
		min_ch = t.min_ch,
		max_cw = t.max_cw,
		max_ch = t.max_ch,
		visible = false,
		maximized = t.maximized,
		--frame
		title = t.title,
		border = framed,
		frame = framed,
		window_edge = framed, --must be off for frameless windows!
		layered = self._layered,
		tool_window = t.frame == 'toolbox',
		owner = t.parent and t.parent.backend.win,
		--behavior
		topmost = t.topmost,
		minimize_button = t.minimizable,
		maximize_button = t.maximizable,
		noclose = not t.closeable,
		sizeable = framed and t.resizeable, --must be off for frameless windows!
		activable = t.activable,
		receive_double_clicks = false, --we do our own double-clicking
		remember_maximized_pos = true, --to emulate OSX behavior for constrained maximized windows
	}

	--must set WS_CHILD **after** window is created for non-activable toolboxes!
	if t.frame == 'toolbox' and not t.activable then
		self.win.child = true
	end

	--init keyboard state
	self.win.__wantallkeys = true --don't let IsDialogMessage() filter out our precious WM_CHARs
	self:_reset_keystate()

	--init mouse state
	self:_update_mouse()

	--start tracking mouse leave
	winapi.TrackMouseEvent{hwnd = self.win.hwnd, flags = winapi.TME_LEAVE}

	--set window state
	self._fullscreen = false

	--set back-references
	self.win.frontend = frontend
	self.win.backend = self
	self.win.app = app

	--set up icon API
	self:_setup_icon_api()

	--register window
	win_map[self.win] = self.frontend

	return self
end

--closing --------------------------------------------------------------------

function window:forceclose()
	self.win._forceclose = true --because win:close() calls on_close().
	self.win:close()
end

function Window:on_close()
	if not self._forceclose and not self.frontend:_backend_closing() then
		return false
	end
end

function Window:nw_destroy()
	self.backend:_free_bitmap()
	self.backend:_free_icon_api()
	win_map[self] = nil
end

--NOTE: closing a window's owner in the on_destroy() event triggers
--another on_destroy() event on the owned window!
function Window:on_destroy()
	if not self.nw_destroying then
		self.nw_destroying = true
		self.frontend:_backend_closed() --this may trigger on_destroy() again!
	end
	if not self.nw_destroyed then
		self.nw_destroyed = true
		self.backend:_free_bitmap()
		self.backend:_free_icon_api()
		win_map[self] = nil
	end
end

--activation -----------------------------------------------------------------

function app:_init_activate()
	self._started = true
	--check for deferred app activation event
	if self._activate then
		self._activate = nil
		if self.frontend:window_count() > 0 then
			self:_activated()
		end
	end
	--check for deferred window activation event
	if self._activate_window then
		local win = self._activate_window
		self._activate_window = nil
		if not win.frontend:dead() then
			win:_activated()
		end
	end
end

function app:_activated()

	if not self._started then
		--defer app activation if the app is not started, to emulate OSX behavior.
		self._activate = true
	elseif not self._active then --ignore duplicate events.
		self._active = true
		self.frontend:_backend_activated()
	end
end

function app:_deactivated()
	if not self._started then
		--remove deferred activation if the app was deactivated before running.
		self._activate = nil
	elseif self._active then --ignore duplicate events.
		self._active = false
		self.frontend:_backend_deactivated()
	end
end

function window:_activated()
	self.app:_activated() --window activation implies app activation.
	self.app._last_active_window = self --for the next app:activate()
	self:_reset_keystate()
	if not self.app._started then
		--defer activation if the app is not started, to emulate OSX behavior.
		self.app._activate_window = self
	elseif not self._active then --ignore duplicate events.
		self._active = true
		self.frontend:_backend_activated()
	end
end

function window:_deactivated()
	self:_reset_keystate()
	if not self.app._started then
		--clear deferred activation if the app is not started, to emulate OSX behavior.
		self.app._activate_window = nil
	elseif self._active then --ignore duplicate events.
		self._active = false
		self.frontend:_backend_deactivated()
	end
end

function app:activate()
	--unlike OSX, in Windows you don't activate an app, you have to activate a specific window.
	--activating this app means activating the last window that was active.
	local win = self._last_active_window
	if win and not win.frontend:dead() then
		win.win:setforeground()
	end
end

function app:active_window()
	--return the active window only if the app is active, to emulate OSX behavior.
	return self._active and win_map[winapi.Windows.active_window] or nil
end

function app:active()
	return self._active
end

function window:activate()
	--if the app is inactive, this function doesn't activate the window,
	--so we want to set _last_active_window for a later call to app:activate(),
	--which will flash this window's button on the taskbar.
	self.app._last_active_window = self
	self.win:activate()
end

function window:active()
	--return the active flag only if the app is active, to emulate OSX behavior.
	return self.app._active and self.win.active or false
end

--this event is received when the window's titlebar is activated.
--we want this event instead of on_activate() because on_activate() is also triggered
--when the app is inactive and the window flashes its taskbar button instead of activating.
function Window:on_nc_activate()
	self.backend:_activated()
end

function Window:on_deactivate()
	self.backend:_deactivated()
end

function Window:on_deactivate_app() --triggered after on_deactivate().
	self.app:_deactivated()
end

--state/visibility -----------------------------------------------------------

function window:visible()
	return self.win.visible
end

function window:show()
	self.win:show()
end

function window:hide()
	self.win:hide()
end

--state/minimizing -----------------------------------------------------------

function window:minimized()
	return self.win.minimized
end

function window:minimize()
	self.win:minimize()
end

--state/maximizing -----------------------------------------------------------

function window:maximized()
	if self._fullscreen then
		return self._fs.maximized
	elseif self.win.minimized then
		return self.win.restore_to_maximized
	end
	return self.win.maximized
end

function window:maximize()
	self.win:maximize()
end

--state/restoring ------------------------------------------------------------

function window:restore()
	self.win:restore()
end

function window:shownormal()
	self.win:shownormal()
end

--state/changed event --------------------------------------------------------

function Window:on_pos_changed(winpos)
	if not self.frontend then return end --not yet hooked
	self.frontend:_backend_changed()
end

--state/fullscreen -----------------------------------------------------------

function window:fullscreen()
	return self._fullscreen
end

function window:enter_fullscreen()
	self._fs = {
		maximized = self:maximized(),
		normal_rect = self.win.normal_rect,
		frame = self.win.frame,
		sizeable = self.win.sizeable,
	}

	--if it's a layered window, clear it, otherwise the taskbar won't
	--dissapear quite immediately when the window will be repainted.
	self:_clear_layered()

	--disable events while we're changing the frame and size.
	local events = self.frontend:events(false)
	self._norepaint = true --invalidate() barrier

	--this flickers, but without it, the taskbar does not dissapear immediately.
	self.win.visible = false

	self.win.frame = false
	self.win.border = false
	self.win.sizeable = false
	local display = self:display() or self.app:active_display()
	local dx, dy, dw, dh = display:rect()
	self.win.normal_rect = pack_rect(nil, dx, dy, dw, dh)

	--center if constrained, to emulate OSX behavior.
	local r = self.win.normal_rect
	pack_rect(r, box2d.align(r.w, r.h, 'center', 'center', dx, dy, dw, dh))
	self.win.normal_rect = r

	self._fullscreen = true
	self.win:shownormal()

	--restore events, and trigger a single resize event and a repaint.
	self._norepaint = false
	self.frontend:events(events)
	self.frontend:_backend_resized()
	self.frontend:_backend_changed()
	self:invalidate()
end

function window:exit_fullscreen()
	--disable events while we're changing the frame and size.
	local events = self.frontend:events(false)
	self._norepaint = true

	if self._fs.maximized then
		self.win:maximize()
	else
		self.win:shownormal()
	end
	self.win.frame = self._fs.frame
	self.win.border = self._fs.frame
	self.win.sizeable = self._fs.sizeable

	self.win.normal_rect = self._fs.normal_rect --we set this after maximize() above.

	self._fullscreen = false

	--restore events, and trigger a single resize event and a repaint.
	self._norepaint = false
	self.frontend:events(events)
	self.frontend:_backend_resized()
	self.frontend:_backend_changed()
	self:invalidate()
end

function Window:on_minimizing()
	--refuse to minimize a fullscreen window to avoid undefined behavior.
	if self.backend._fullscreen then
		return false
	end
end

--positioning/conversions ----------------------------------------------------

function window:to_screen(x, y)
	local p = self.win:map_point(nil, x, y)
	return p.x, p.y
end

function window:to_client(x, y)
	local p = winapi.Windows:map_point(self.win, x, y)
	return p.x, p.y
end

local function frame_args(frame)
	local framed = frame == 'normal' or frame == 'toolbox'
	local layered = frame == 'none-transparent'
	return {
		border = framed,
		frame = framed,
		window_edge = framed,
		sizeable = framed,
		layered = layered,
	}
end

function app:client_to_frame(frame, x, y, w, h)
	return unpack_rect(winapi.Window:client_to_frame(frame_args(frame),
		pack_rect(nil, x, y, w, h)))
end

function app:frame_to_client(frame, x, y, w, h)
	return unpack_rect(winapi.Window:frame_to_client(frame_args(frame),
		pack_rect(nil, x, y, w, h)))
end

--positioning/rectangles -----------------------------------------------------

function window:get_normal_rect()
	if self._fullscreen then
		return unpack_rect(self._fs.normal_rect)
	else
		return unpack_rect(self.win.normal_rect)
	end
end

function window:set_normal_rect(x, y, w, h)
	if self._fullscreen then
		self._fs.normal_rect = pack_rect(nil, x, y, w, h)
	else
		self.win.normal_rect = pack_rect(nil, x, y, w, h)
		self.frontend:_backend_resized()
	end
end

function window:get_frame_rect()
	return unpack_rect(self.win.screen_rect)
end

function window:set_frame_rect(x, y, w, h)
	self:set_normal_rect(x, y, w, h)
	if self:visible() then
		self:shownormal()
	end
end

function window:get_size()
	local r = self.win.client_rect
	return r.w, r.h
end

--positioning/constraints ----------------------------------------------------

function window:get_minsize()
	return self.win.min_cw, self.win.min_ch
end

function window:set_minsize(w, h)
	self.win.min_cw = w
	self.win.min_ch = h
	self.win:resize(self.win.w, self.win.h)
end

function window:get_maxsize()
	return self.win.max_cw, self.win.max_ch
end

function window:set_maxsize(w, h)
	self.win.max_cw = w
	self.win.max_ch = h
	self.win:resize(self.win.w, self.win.h)
end

--positioning/resizing -------------------------------------------------------

function Window:on_begin_sizemove()
	--when moving the window, we want its position relative to
	--the mouse position to remain constant, and we're going to enforce that.
	local m = winapi.Windows.cursor_pos
	self.nw_dx = m.x - self.x
	self.nw_dy = m.y - self.y

	--defer the start_resize event because we don't know whether
	--it's a move or resize event at this point.
	self.nw_start_resize = true
end

function Window:on_end_sizemove()
	self.nw_start_resize = false
	local how = self.nw_sizemove_how
	self.nw_sizemove_how = nil
	self.frontend:_backend_end_resize(how)

	--fix bug where moving non-activable child toolboxes deactivates the parent.
	if not self.frontend:activable() then
		self.frontend:parent():activate()
	end
end

function Window:nw_frame_changing(how, rect)

	self.nw_sizemove_how = how

	--trigger the deferred start_resize event, once.
	if self.nw_start_resize then
		self.nw_start_resize = false
		self.frontend:_backend_start_resize(how)
	end

	if how == 'move' then
		--set window's position based on current mouse position and initial offset,
		--regardless of how the coordinates are adjusted by the user on each event.
		--this also emulates the default OSX behavior.
		local m = winapi.Windows.cursor_pos
		rect.x = m.x - self.nw_dx
		rect.y = m.y - self.nw_dy
	end

	pack_rect(rect, self.frontend:_backend_resizing(how, unpack_rect(rect)))

	if how == 'move' then

		--fix winapi bug where non-activable toolbox windows don't show contents while moving.
		if not self.frontend:activable() then
			local x, y, w, h = unpack_rect(rect)
			--NOTE: SWP_NOACTIVATE has no effect here, so might as well pass 0.
			winapi.SetWindowPos(self.hwnd, nil, x, y, w, h, 0)
		end

		--move children too, to emulate OSX behavior.
		local x, y = rect.x, rect.y
		local x0, y0 = self.backend:get_frame_rect()
		local dx = x - x0
		local dy = y - y0
		for _,win in ipairs(self.frontend:children()) do
			local x, y = win:frame_rect()
			win:frame_rect(x + dx, y + dy)
		end

	end
end

function Window:on_moving(rect)
	self:nw_frame_changing('move', rect)
	return true --signal that the position was modified
end

function Window:on_resizing(how, rect)
	self:nw_frame_changing(how, rect)
end

function Window:on_moved()
	self.frontend:_backend_resized()
end

function Window:on_resized(flag)

	--early event, ignore.
	if not self.frontend then return end

	if flag == 'minimized' then

		self.frontend:_backend_resized()

	elseif flag == 'maximized' then

		if self.nw_maximizing then return end

		--frameless windows maximize to the entire screen, covering the taskbar. fix that.
		if not self.frame then
			self.nw_maximizing = true --on_resized() barrier
			self.rect = pack_rect(nil, self.backend:display():client_rect())
			self.nw_maximizing = false
		end

		self.backend:invalidate()
		self.frontend:_backend_resized()

	elseif flag == 'restored' then --also triggered on show

		self.backend:invalidate()
		self.frontend:_backend_resized()

	end
end

--positioning/magnets --------------------------------------------------------

function window:magnets()
	local t = {} --{{x, y, w, h}, ...}
	local rect
	for i,hwnd in ipairs(winapi.EnumChildWindows()) do --front-to-back order assured
		if hwnd ~= self.win.hwnd         --exclude self
			and winapi.IsVisible(hwnd)    --exclude invisible
			and not winapi.IsZoomed(hwnd) --exclude maximized (TODO: also excludes constrained maximized)
		then
			rect = winapi.GetWindowRect(hwnd, rect)
			t[#t+1] = {x = rect.x, y = rect.y, w = rect.w, h = rect.h}
		end
	end
	return t
end

--titlebar -------------------------------------------------------------------

function window:get_title()
	return self.win.title
end

function window:set_title(title)
	self.win.title = title
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return self.win.topmost
end

function window:set_topmost(topmost)
	self.win.topmost = topmost
end

function window:set_zorder(mode, relto)
	if mode == 'back' then
		self.win:send_to_back(relto)
	elseif mode == 'front' then
		self.win:bring_to_front(relto)
	end
end

--displays -------------------------------------------------------------------

require'winapi.monitor'

function app:_display(monitor)
	local ok, info = pcall(winapi.GetMonitorInfo, monitor)
	if not ok then return end
	return self.frontend:_display{
		x = info.monitor_rect.x,
		y = info.monitor_rect.y,
		w = info.monitor_rect.w,
		h = info.monitor_rect.h,
		client_x = info.work_rect.x,
		client_y = info.work_rect.y,
		client_w = info.work_rect.w,
		client_h = info.work_rect.h,
	}
end

function app:displays()
	local monitors = winapi.EnumDisplayMonitors()
	local displays = {}
	for i = 1, #monitors do
		table.insert(displays, self:_display(monitors[i])) --invalid displays are skipped
	end
	return displays
end

function app:active_display()
	local hwnd = winapi.GetForegroundWindow()
	if hwnd then
		return self:_display(winapi.MonitorFromWindow(hwnd, 'MONITOR_DEFAULTTONEAREST'))
	else
		--in case there's no foreground window, fallback to the display
		--where the mouse pointer is. if there's no mouse, then fallback to the primary display.
		local p = winapi.GetCursorPos()
		return self:_display(winapi.MonitorFromPoint(p, 'MONITOR_DEFAULTTOPRIMARY'))
	end
end

function app:display_count()
	return winapi.GetSystemMetrics'SM_CMONITORS'
end

--NOTE: the default flag for self.win.monitor is MONITOR_DEFAULTTONULL,
--which is what we need to emulate OSX behavior for off-screen windows.
function window:display()
	return self.app:_display(self.win.monitor)
end

function Window:on_display_change(x, y, bpp)
	self.app.frontend:_backend_displays_changed()
end

--cursors --------------------------------------------------------------------

require'winapi.cursor'

local cursors = {
	--pointers
	arrow = winapi.IDC_ARROW,
	ibeam = winapi.IDC_IBEAM,
	hand  = winapi.IDC_HAND,
	cross = winapi.IDC_CROSS,
	no    = winapi.IDC_NO,
	--move and resize
	nwse  = winapi.IDC_SIZENWSE,
	nesw  = winapi.IDC_SIZENESW,
	we    = winapi.IDC_SIZEWE,
	ns    = winapi.IDC_SIZENS,
	move  = winapi.IDC_SIZEALL,
	--app state
	--wait  = winapi.IDC_WAIT, --not in OSX
	busy  = winapi.IDC_APPSTARTING,
}

function window:cursor(name)
	if name ~= nil then
		self._cursor = name
		self:invalidate()
	else
		return self._cursor
	end
end

function Window:on_set_cursor(_, ht)
	if ht ~= winapi.HTCLIENT then return end
	local cursor = cursors[self.backend._cursor]
	if not cursor then return end
	winapi.SetCursor(winapi.LoadCursor(cursor))
	return true --important
end

--keyboard -------------------------------------------------------------------

require'winapi.keyboard'
require'winapi.rawinput'

local keynames = { --vkey code -> vkey name

	[winapi.VK_OEM_1]      = ';',  --on US keyboards
	[winapi.VK_OEM_PLUS]   = '=',
 	[winapi.VK_OEM_COMMA]  = ',',
	[winapi.VK_OEM_MINUS]  = '-',
	[winapi.VK_OEM_PERIOD] = '.',
	[winapi.VK_OEM_2]      = '/',  --on US keyboards
	[winapi.VK_OEM_3]      = '`',  --on US keyboards
	[winapi.VK_OEM_4]      = '[',  --on US keyboards
	[winapi.VK_OEM_5]      = '\\', --on US keyboards
	[winapi.VK_OEM_6]      = ']',  --on US keyboards
	[winapi.VK_OEM_7]      = '\'', --on US keyboards

	[winapi.VK_BACK]   = 'backspace',
	[winapi.VK_TAB]    = 'tab',
	[winapi.VK_SPACE]  = 'space',
	[winapi.VK_ESCAPE] = 'esc',

	[winapi.VK_F1]  = 'F1',
	[winapi.VK_F2]  = 'F2',
	[winapi.VK_F3]  = 'F3',
	[winapi.VK_F4]  = 'F4',
	[winapi.VK_F5]  = 'F5',
	[winapi.VK_F6]  = 'F6',
	[winapi.VK_F7]  = 'F7',
	[winapi.VK_F8]  = 'F8',
	[winapi.VK_F9]  = 'F9',
	[winapi.VK_F10] = 'F10',
	[winapi.VK_F11] = 'F11',
	[winapi.VK_F12] = 'F12',

	[winapi.VK_CAPITAL]  = 'capslock',
	[winapi.VK_NUMLOCK]  = 'numlock',     --win keyboard; mapped to 'numclear' on mac
	[winapi.VK_SNAPSHOT] = 'printscreen', --win keyboard; mapped to 'F13' on mac; taken on windows (screen snapshot)
	[winapi.VK_SCROLL]   = 'scrolllock',  --win keyboard; mapped to 'F14' on mac

	[winapi.VK_NUMPAD0] = 'num0',
	[winapi.VK_NUMPAD1] = 'num1',
	[winapi.VK_NUMPAD2] = 'num2',
	[winapi.VK_NUMPAD3] = 'num3',
	[winapi.VK_NUMPAD4] = 'num4',
	[winapi.VK_NUMPAD5] = 'num5',
	[winapi.VK_NUMPAD6] = 'num6',
	[winapi.VK_NUMPAD7] = 'num7',
	[winapi.VK_NUMPAD8] = 'num8',
	[winapi.VK_NUMPAD9] = 'num9',
	[winapi.VK_DECIMAL] = 'num.',
	[winapi.VK_MULTIPLY] = 'num*',
	[winapi.VK_ADD]      = 'num+',
	[winapi.VK_SUBTRACT] = 'num-',
	[winapi.VK_DIVIDE]   = 'num/',
	[winapi.VK_CLEAR]    = 'numclear',

	[winapi.VK_VOLUME_MUTE] = 'mute',
	[winapi.VK_VOLUME_DOWN] = 'volumedown',
	[winapi.VK_VOLUME_UP]   = 'volumeup',

	[0xff]           = 'lwin', --win keyboard; mapped to 'lcommand' on mac
	[winapi.VK_RWIN] = 'rwin', --win keyboard; mapped to 'rcommand' on mac
	[winapi.VK_APPS] = 'menu', --win keyboard

	[winapi.VK_OEM_NEC_EQUAL] = 'num=', --mac keyboard
}

for ascii = string.byte('0'), string.byte('9') do --ASCII 0-9 -> '0'-'9'
	keynames[ascii] = string.char(ascii)
end

for ascii = string.byte('A'), string.byte('Z') do --ASCII A-Z -> 'A'-'Z'
	keynames[ascii] = string.char(ascii)
end

local keynames_ext = {}

keynames_ext[false] = { --vkey code -> vkey name when flags.extended_key is false

	[winapi.VK_CONTROL] = 'lctrl',
	[winapi.VK_MENU]    = 'lalt',

	[winapi.VK_LEFT]   = 'numleft',
	[winapi.VK_UP]     = 'numup',
	[winapi.VK_RIGHT]  = 'numright',
	[winapi.VK_DOWN]   = 'numdown',
	[winapi.VK_PRIOR]  = 'numpageup',
	[winapi.VK_NEXT]   = 'numpagedown',
	[winapi.VK_END]    = 'numend',
	[winapi.VK_HOME]   = 'numhome',
	[winapi.VK_INSERT] = 'numinsert',
	[winapi.VK_DELETE] = 'numdelete',
	[winapi.VK_RETURN] = 'enter!',
}

keynames_ext[true] = { --vkey code -> vkey name when flags.extended_key is true

	[winapi.VK_CONTROL] = 'rctrl',
	[winapi.VK_MENU]    = 'ralt',

	[winapi.VK_LEFT]    = 'left!',
	[winapi.VK_UP]      = 'up!',
	[winapi.VK_RIGHT]   = 'right!',
	[winapi.VK_DOWN]    = 'down!',
	[winapi.VK_PRIOR]   = 'pageup!',
	[winapi.VK_NEXT]    = 'pagedown!',
	[winapi.VK_END]     = 'end!',
	[winapi.VK_HOME]    = 'home!',
	[winapi.VK_INSERT]  = 'insert!',
	[winapi.VK_DELETE]  = 'delete!',
	[winapi.VK_RETURN]  = 'numenter',
}

local keycodes = {}
for vk, name in pairs(keynames) do
	keycodes[name:lower()] = vk
end

--additional key codes that we can query directly
keycodes.lctrl    = winapi.VK_LCONTROL
keycodes.lalt     = winapi.VK_LMENU
keycodes.rctrl    = winapi.VK_RCONTROL
keycodes.ralt     = winapi.VK_RMENU

--ambiguous key codes that we can query directly
keycodes.ctrl     = winapi.VK_CONTROL
keycodes.alt      = winapi.VK_MENU
keycodes.left     = winapi.VK_LEFT
keycodes.up       = winapi.VK_UP
keycodes.right    = winapi.VK_RIGHT
keycodes.down     = winapi.VK_DOWN
keycodes.pageup   = winapi.VK_PRIOR
keycodes.pagedown = winapi.VK_NEXT
keycodes['end']   = winapi.VK_END
keycodes.home     = winapi.VK_HOME
keycodes.insert   = winapi.VK_INSERT
keycodes.delete   = winapi.VK_DELETE
keycodes.enter    = winapi.VK_RETURN

local ignore_numlock_keys = {
	numdelete   = 'num.',
	numinsert   = 'num0',
	numend      = 'num1',
	numdown     = 'num2',
	numpagedown = 'num3',
	numleft     = 'num4',
	numclear    = 'num5',
	numright    = 'num6',
	numhome     = 'num7',
	numup       = 'num8',
	numpageup   = 'num9',
}

local numlock_off_keys = glue.index(ignore_numlock_keys)

local keystate     --key state for keys that we can't get with GetKeyState()
local repeatstate  --repeat state for keys we want to prevent repeating for.
local altgr        --altgr flag, indicating that the next 'ralt' is actually 'altgr'.
local realkey      --set via raw input to distinguish break from ctrl+numlock, etc.

function window:_reset_keystate()
	keystate = {}
	repeatstate = {}
	altgr = nil
	realkey = nil
end

function Window:setkey(vk, flags, down)
	if vk == winapi.VK_SHIFT then
		return --shift is handled using raw input because we don't get key up on shift if the other shift is pressed!
	end
	if winapi.IsAltGr(vk, flags) then
		altgr = true --next key is 'ralt' which we'll make into 'altgr'
		return
	end
	local name = realkey or keynames_ext[flags.extended_key][vk] or keynames[vk]
	realkey = nil --reset realkey. important!
	if altgr then
		altgr = nil
		if name == 'ralt' then
			name = 'altgr'
		end
	end
	local searchname = name:lower()
	if not keycodes[searchname] then --save the state of this key because we can't get it with GetKeyState()
		keystate[searchname] = down
	end
	if self.app.frontend:ignore_numlock() then --ignore the state of the numlock key (for games)
		name = ignore_numlock_keys[name] or name
	end
	return name
end

--prevent repeating these keys to emulate OSX behavior, and also because flags.prev_key_state
--doesn't work on them.
local norepeat = glue.index{'lshift', 'rshift', 'lalt', 'ralt', 'altgr', 'lctrl', 'rctrl', 'capslock'}

function Window:on_key_down(vk, flags)
	local key = self:setkey(vk, flags, true)
	if not key then return end
	if norepeat[key] then
		if not repeatstate[key] then
			repeatstate[key] = true
			self.frontend:_backend_keydown(key)
			self.frontend:_backend_keypress(key)
		end
	elseif not flags.prev_key_state then
		self.frontend:_backend_keydown(key)
		self.frontend:_backend_keypress(key)
	else
		self.frontend:_backend_keypress(key)
	end
end

function Window:on_key_up(vk, flags)
	local key = self:setkey(vk, flags, false)
	if not key then return end
	if norepeat[key] then
		repeatstate[key] = false
	end
	self.frontend:_backend_keyup(key)
end

--we get the ALT key with these messages instead
Window.on_syskey_down = Window.on_key_down
Window.on_syskey_up = Window.on_key_up

function Window:on_key_down_char(char)
	self.frontend:_backend_keychar(char)
end

Window.on_syskey_down_char = Window.on_key_down_char

--take control of the ALT and F10 keys
function Window:on_menu_key(char_code)
	if char_code == 0 then
		return false
	end
end

local toggle_keys = glue.index{'capslock', 'numlock', 'scrolllock'}

function window:key(name) --name is in lowercase!
	if name:find'^%^' then --'^key' means get the toggle state for that key
		name = name:sub(2)
		if not toggle_keys[name] then return false end --windows has toggle state for all keys, we don't want that.
		local keycode = keycodes[name]
		if not keycode then return false end
		local _, on = winapi.GetKeyState(keycode)
		return on
	else
		if numlock_off_keys[name]
			and self.app.frontend:ignore_numlock()
			and not self:key'^numlock'
		then
			return self:key(numlock_off_keys[name])
		end
		local keycode = keycodes[name]
		if keycode then
			return (winapi.GetKeyState(keycode))
		else
			return keystate[name] or false
		end
	end
end

function Window:on_raw_input(raw)

	local vk = raw.data.keyboard.VKey
	if vk == winapi.VK_SHIFT then
		vk = winapi.MapVirtualKey(raw.data.keyboard.MakeCode, winapi.MAPVK_VSC_TO_VK_EX)
		local key = vk == winapi.VK_LSHIFT and 'lshift' or 'rshift'
		if bit.band(raw.data.keyboard.Flags, winapi.RI_KEY_BREAK) == 0 then --keydown
			if not repeatstate[key] then
				keystate.shift = true
				keystate[key] = true
				repeatstate[key] = true
				self.frontend:_backend_keydown(key)
				self.frontend:_backend_keypress(key)
			end
		else
			keystate.shift = false
			keystate[key] = false
			repeatstate[key] = false
			self.frontend:_backend_keyup(key)
		end
	elseif vk == winapi.VK_PAUSE then
		if bit.band(raw.data.keyboard.Flags, winapi.RI_KEY_E1) == 0 then --Ctrl+Numlock
			realkey = 'numlock'
		else
			realkey = 'break'
		end
	elseif vk == winapi.VK_CANCEL then
		if bit.band(raw.data.keyboard.Flags, winapi.RI_KEY_E0) == 0 then --Ctrl+ScrollLock
			realkey = 'scrolllock'
		else
			realkey = 'break'
		end
	end
end

--mouse ----------------------------------------------------------------------

require'winapi.mouse'

function app:double_click_time() --milliseconds
	return winapi.GetDoubleClickTime()
end

function app:double_click_target_area()
	local w = winapi.GetSystemMetrics'SM_CXDOUBLECLK'
	local h = winapi.GetSystemMetrics'SM_CYDOUBLECLK'
	return w, h
end

--TODO: get lost mouse events http://blogs.msdn.com/b/oldnewthing/archive/2012/03/14/10282406.aspx

local function unpack_buttons(b)
	return b.lbutton, b.rbutton, b.mbutton, b.xbutton1, b.xbutton2
end

function window:_update_mouse()
	local m = self.frontend._mouse
	local pos = self.win.cursor_pos
	m.x = pos.x
	m.y = pos.y
	m.left   = winapi.GetKeyState(winapi.VK_LBUTTON)
	m.middle = winapi.GetKeyState(winapi.VK_MBUTTON)
	m.right  = winapi.GetKeyState(winapi.VK_RBUTTON)
	m.ex1    = winapi.GetKeyState(winapi.VK_XBUTTON1)
	m.ex2    = winapi.GetKeyState(winapi.VK_XBUTTON2)
	m.inside = box2d.hit(m.x, m.y, unpack_rect(self.win.client_rect))
end

function window:_setmouse(x, y, buttons)

	--set mouse state
	local m = self.frontend._mouse
	m.x = x
	m.y = y
	m.left = buttons.lbutton
	m.right = buttons.rbutton
	m.middle = buttons.mbutton
	m.ex1 = buttons.xbutton1
	m.ex2 = buttons.xbutton2

	--send hover
	if not m.inside then
		m.inside = true
		winapi.TrackMouseEvent{hwnd = self.win.hwnd, flags = winapi.TME_LEAVE}
		self.frontend:_backend_mouseenter()
	end
end

function Window:on_mouse_move(x, y, buttons)
	local m = self.frontend._mouse
	self.backend:_setmouse(x, y, buttons)
	self.frontend:_backend_mousemove(x, y)
end

function Window:on_mouse_leave()
	if not self.frontend._mouse.inside then return end
	self.frontend._mouse.inside = false
	self.frontend:_backend_mouseleave()
end

function Window:capture_mouse()
	self.capture_count = (self.capture_count or 0) + 1
	winapi.SetCapture(self.hwnd)
end

function Window:uncapture_mouse()
	self.capture_count = math.max(0, (self.capture_count or 0) - 1)
	if self.capture_count == 0 then
		winapi.ReleaseCapture()
	end
end

function Window:on_lbutton_down(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:capture_mouse()
	self.frontend:_backend_mousedown('left', x, y)
end

function Window:on_mbutton_down(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:capture_mouse()
	self.frontend:_backend_mousedown('middle', x, y)
end

function Window:on_rbutton_down(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:capture_mouse()
	self.frontend:_backend_mousedown('right', x, y)
end

function Window:on_xbutton_down(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:capture_mouse()
		self.frontend:_backend_mousedown('ex1', x, y)
	end
	if buttons.xbutton2 then
		self:capture_mouse()
		self.frontend:_backend_mousedown('ex2', x, y)
	end
end

function Window:on_lbutton_up(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.frontend:_backend_mouseup('left', x, y)
end

function Window:on_mbutton_up(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.frontend:_backend_mouseup('middle', x, y)
end

function Window:on_rbutton_up(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.frontend:_backend_mouseup('right', x, y)
end

function Window:on_xbutton_up(x, y, buttons)
	self.backend:_setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:uncapture_mouse()
		self.frontend:_backend_mouseup('ex1', x, y)
	end
	if buttons.xbutton2 then
		self:uncapture_mouse()
		self.frontend:_backend_mouseup('ex2', x, y)
	end
end

local wsl_buf = ffi.new'UINT[1]'
local function wheel_scroll_lines()
	winapi.SystemParametersInfo(winapi.SPI_GETWHEELSCROLLLINES, 0, wsl_buf)
	return wsl_buf[0]
end

function Window:on_mouse_wheel(x, y, buttons, delta)
	if (delta - 1) % 120 == 0 then --correction for my ms mouse when scrolling back
		delta = delta - 1
	end
	delta = delta / 120 * wheel_scroll_lines()
	self.backend:_setmouse(x, y, buttons)
	self.frontend:_backend_mousewheel(delta, x, y)
end

local function wheel_scroll_chars()
	self.wsc_buf = self.wsc_buf or ffi.new'UINT[1]'
	winapi.SystemParametersInfo(winapi.SPI_GETWHEELSCROLLCHARS, 0, self.wsc_buf)
	return self.wsc_buf[0]
end

function Window:on_mouse_hwheel(x, y, buttons, delta)
	delta = delta / 120 * wheel_scroll_chars()
	self.backend:_setmouse(x, y, buttons)
	self.frontend:_backend_mousehwheel(delta, x, y)
end

function window:mouse_pos()
	return winapi.GetMessagePos()
end

--bitmaps --------------------------------------------------------------------

--initialize a new or existing DIB header for a top-down bgra8 bitmap.
local function dib_header(w, h, bi)
	if bi then
		ffi.fill(bi, ffi.sizeof'BITMAPV5HEADER')
		bi.bV5Size = ffi.sizeof'BITMAPV5HEADER'
	else
		bi = winapi.BITMAPV5HEADER()
	end
	bi.bV5Width  = w
	bi.bV5Height = -h
	bi.bV5Planes = 1
	bi.bV5BitCount = 32
	bi.bV5Compression = winapi.BI_BITFIELDS
	bi.bV5SizeImage = w * h * 4
	--this mask specifies a supported 32bpp alpha format for Windows XP.
	bi.bV5RedMask   = 0x00FF0000
	bi.bV5GreenMask = 0x0000FF00
	bi.bV5BlueMask  = 0x000000FF
	bi.bV5AlphaMask = 0xFF000000
	--this flag is important for making clipboard-compatible packed DIBs!
	bi.bV5CSType = winapi.LCS_WINDOWS_COLOR_SPACE
	return bi
end

--make a top-down bgra8 DIB and return it along with the pixel buffer.
local function dib(w, h)
	local bi = dib_header(w, h)
	local info = ffi.cast('BITMAPINFO*', bi)
	local hdc = winapi.GetDC()
	local hbmp, data = winapi.CreateDIBSection(hdc, info, winapi.DIB_RGB_COLORS)
	winapi.ReleaseDC(nil, hdc)
	return hbmp, data
end

--make a top-down bgra8 DIB with a bitmap frontend for access to pixels.
local function dib_bitmap(w, h, data)
	return {
		w = w,
		h = h,
		data = data,
		stride = w * 4,
		size = w * h * 4,
		format = 'bgra8',
	}
end

--make a DIB and APIs to paint the DIB on a DC and on a WS_EX_LAYERED window.
local function dib_bitmap_api(w, h)

	--can't create a zero-sized bitmap
	if w <= 0 or h <= 0 then return end

	local hbmp, data = dib(w, h)
	local bitmap = dib_bitmap(w, h, data)
	local hdc = winapi.CreateCompatibleDC()
	local oldhbmp = winapi.SelectObject(hdc, hbmp)

	local api = {bitmap = bitmap, hbmp = hbmp}

	--paint the bitmap on a DC.
	function api:paint(dest_hdc)
		winapi.BitBlt(dest_hdc, 0, 0, w, h, hdc, 0, 0, winapi.SRCCOPY)
	end

	--update a WS_EX_LAYERED window with the bitmap contents and size.
	--the bitmap must have window's client rectangle size, otherwise
	--Windows **resizes the window** to the size of the bitmap.
	local pos = winapi.POINT()
	local topleft = winapi.POINT()
	local size = winapi.SIZE(w, h)
	local blendfunc = winapi.types.BLENDFUNCTION{
		AlphaFormat = winapi.AC_SRC_ALPHA,
		BlendFlags = 0,
		BlendOp = winapi.AC_SRC_OVER,
		SourceConstantAlpha = 255,
	}
	function api:update_layered(win)
		local r = win.screen_rect
		pos.x = r.x
		pos.y = r.y
		winapi.UpdateLayeredWindow(win.hwnd, nil, pos, size, hdc, topleft, 0,
			blendfunc, winapi.ULW_ALPHA)
	end

	function api:free()
		--trigger a user-supplied destructor.
		if bitmap.free then
			bitmap:free()
		end
		--free the bitmap and dc.
		winapi.SelectObject(hdc, oldhbmp)
		winapi.DeleteObject(hbmp)
		winapi.DeleteDC(hdc)
		bitmap.data = nil
		bitmap = nil
	end

	return api
end

--a dynamic bitmap is an API that creates a new bitmap everytime its size
--changes. user supplies the :size() function, :get() gets the bitmap,
--and :freeing(bitmap) is triggered before the bitmap is freed.
local function dynbitmap(api)

	api = api or {}

	local w, h, dib

	function api:get()
		local w1, h1 = api:size()
		if w1 ~= w or h1 ~= h then
			self:free()
			dib = dib_bitmap_api(w1, h1)
			w, h = w1, h1
		end
		return dib and dib.bitmap
	end

	function api:free()
		if not dib then return end
		self:freeing(dib.bitmap)
		dib:free()
	end

	function api:paint(hdc)
		if not dib then return end
		dib:paint(hdc)
	end

	function api:update_layered(win)
		if not dib then return end
		dib:update_layered(win)
	end

	return api
end

--rendering ------------------------------------------------------------------

function window:_create_dynbitmap()
	if self._dynbitmap then return end
	self._dynbitmap = dynbitmap{
		size = function()
			return self.frontend:size()
		end,
		freeing = function(_, bitmap)
			self.frontend:_backend_free_bitmap(bitmap)
			self._bitmap = nil
		end,
	}
end

function window:bitmap()
	self:_create_dynbitmap()
	self._bitmap = self._dynbitmap:get()
	return self._bitmap
end

function window:_free_bitmap()
	if not self._bitmap then return end
	self._dynbitmap:free()
end

function window:_paint_bitmap(hdc)
	if not self._bitmap then return end
	self._dynbitmap:paint(hdc)
end

function window:_update_layered()
	if not self._bitmap then return end
	self._dynbitmap:update_layered(self.win)
end

function window:invalidate()
	if self._norepaint then return end
	if self._layered then
		self.frontend:_backend_repaint()
		self:_update_layered()
	else
		self.win:invalidate()
	end
end

--clear the bitmap's pixels and update the layered window.
function window:_clear_layered()
	if not self._bitmap or not self._layered then return end
	local bmp = self._bitmap
	ffi.fill(bmp.data, bmp.stride * bmp.h)
	self:_update_layered()
end

function Window:WM_ERASEBKGND()
	if not self.backend._dynbitmap then return end
	return false --skip drawing the background to prevent flicker.
end

function Window:on_paint(hdc)
	self.frontend:_backend_repaint()
	self.backend:_paint_bitmap(hdc)
end

--views ----------------------------------------------------------------------

local view = {}
window.view = view

function view:new(window, frontend, t)
	local self = glue.inherit({
		window = window,
		app = window.app,
		frontend = frontend,
	}, self)

	self:_init(t)

	return self
end

glue.autoload(window, {
	glview    = 'nw_winapi_glview',
	cairoview = 'nw_winapi_cairoview',
	cairoview2 = 'nw_winapi_cairoview2',
})

function window:getcairoview()
	if self._layered then
		return self.cairoview
	else
		return self.cairoview2
	end
end

--menus ----------------------------------------------------------------------

local menu = {}

function app:menu()
	return menu:_new(winapi.Menu())
end

function menu:_new(winmenu)
	local self = glue.inherit({winmenu = winmenu}, menu)
	winmenu.nw_backend = self
	return self
end

local function menuitem(args)
	return {
		text = args.text,
		separator = args.separator,
		on_click = args.action,
		submenu = args.submenu and args.submenu.backend.winmenu,
		checked = args.checked,
		enabled = args.enabled,
	}
end

local function dump_menuitem(mi)
	return {
		text = mi.text,
		action = mi.submenu and mi.submenu.nw_backend.frontend or mi.on_click,
		checked = mi.checked,
		enabled = mi.enabled,
	}
end

function menu:add(index, args)
	return self.winmenu.items:add(index, menuitem(args))
end

function menu:set(index, args)
	self.winmenu.items:set(index, menuitem(args))
end

function menu:get(index)
	return dump_menuitem(self.winmenu.items:get(index))
end

function menu:item_count()
	return self.winmenu.items.count
end

function menu:remove(index)
	self.winmenu.items:remove(index)
end

function menu:get_checked(index)
	return self.winmenu.items:checked(index)
end

function menu:set_checked(index, checked)
	self.winmenu.items:setchecked(index, checked)
end

function menu:get_enabled(index)
	return self.winmenu.items:enabled(index)
end

function menu:set_enabled(index, enabled)
	self.winmenu.items:setenabled(index, enabled)
end

--in Windows, each window has its own menu bar.
function window:menubar()
	if not self._menu then
		local menubar = winapi.MenuBar()
		self.win.menu = menubar
		self._menu = menu:_new(menubar)
	end
	return self._menu
end

function window:popup(menu, x, y)
	menu.backend.winmenu:popup(self.win, x, y)
end

--notification icons ---------------------------------------------------------

require'winapi.notifyiconclass'

local notifyicon = {}
app.notifyicon = notifyicon

local NotifyIcon = winapi.subclass({}, winapi.NotifyIcon)

--get the singleton hidden window used to route mouse messages through.
local notifywindow
function notifyicon:_notify_window()
	notifywindow = notifywindow or winapi.Window{visible = false}
	return notifywindow
end

function notifyicon:new(app, frontend, opt)
	self = glue.inherit({app = app, frontend = frontend}, notifyicon)

	self.ni = NotifyIcon{window = self:_notify_window()}
	self.ni.backend = self
	self.ni.frontend = frontend

	self:_setup_icon_api()

	return self
end

function notifyicon:free()
	self.ni:free()
	self:_free_icon_api()
	self.ni = nil
end

function NotifyIcon:on_rbutton_up()
	--if a menu was assigned, pop it up on right-click.
	local menu = self.backend.menu
	if menu and not menu:dead() then
		local win = self.backend:_notify_window()
		local pos = win.cursor_pos
		menu.backend.winmenu:popup(win, pos.x, pos.y)
	end
end

--make an API composed of three functions: one that gives you a bgra8 bitmap
--to draw into, another that creates a new icon everytime it is called with
--the contents of that bitmap, and a third one to free the icon and bitmap.
--the bitmap is recreated only if the icon size changed since last access.
--the bitmap is in bgra8 format, premultiplied alpha.
local function icon_api(which)

	local w, h, bmp, data, maskbmp

	local function free_bitmaps()
		if not bmp then return end
		winapi.DeleteObject(bmp)
		winapi.DeleteObject(maskbmp)
		w, h, bmp, data, maskbmp = nil
	end

	local function recreate_bitmaps(w1, h1)
		free_bitmaps()
		w, h = w1, h1
		--create a bgra8 bitmap.
		bmp, data = dib(w, h)
		--create an empty mask bitmap.
		maskbmp = winapi.CreateBitmap(w, h, 1, 1)
	end

	local icon

	local function free_icon()
		if not icon then return end
		winapi.DestroyIcon(icon)
		icon = nil
	end

	local function recreate_icon()
		free_icon()

		local ii = winapi.ICONINFO()
		ii.fIcon = true --icon, not cursor
		ii.xHotspot = 0
		ii.yHotspot = 0
		ii.hbmMask = maskbmp
		ii.hbmColor = bmp

		icon = winapi.CreateIconIndirect(ii)
	end

	local function size()
		local SM = which == 'small' and 'SM_CXSMICON' or 'SM_CXICON'
		local w = winapi.GetSystemMetrics(SM)
		local h = winapi.GetSystemMetrics(SM)
		return w, h
	end

	local bitmap

	local function get_bitmap()
		local w1, h1 = size()
		if w1 ~= w or h1 ~= h then
			recreate_bitmaps(w1, h1)
			bitmap = {
				w = w,
				h = h,
				data = data,
				stride = w * 4,
				size = w * h * 4,
				format = 'bgra8',
			}
		end
		return bitmap
	end

	local function get_icon()
		if not bmp then return end

		--counter-hack: in windows, an all-around zero-alpha image is shown as black.
		--we set the second pixel's alpha to a non-zero value to prevent this.
		local data = ffi.cast('int8_t*', data)
		for i = 3, w * h - 1, 4 do
			if data[i] ~= 0 then goto skip end
		end
		data[7] = 1 --write a low alpha value to the second pixel so it looks invisible.
		::skip::

		recreate_icon()
		return icon
	end

	local function free_all()
		free_bitmaps()
		free_icon()
	end

	return get_bitmap, get_icon, free_all
end

function notifyicon:_setup_icon_api()
	self.bitmap, self._get_icon, self._free_icon_api = icon_api()
end

function notifyicon:invalidate()
	self.frontend:_backend_repaint()
	self.ni.icon = self:_get_icon()
end

function notifyicon:get_tooltip()
	return self.ni.tip
end

function notifyicon:set_tooltip(tooltip)
	self.ni.tip = tooltip
end

function notifyicon:get_menu()
	return self.menu
end

function notifyicon:set_menu(menu)
	self.menu = menu
end

function notifyicon:rect()
	return 0, 0, 0, 0 --TODO
end

--window icon ----------------------------------------------------------------

local function whicharg(which)
	assert(which == nil or which == 'small' or which == 'big')
	return which == 'small' and 'small' or 'big'
end

function window:_add_icon_api(which)
	which = whicharg(which)
	local get_bitmap, get_icon, free_all = icon_api(which)
	self._icon_api[which] = {get_bitmap = get_bitmap, get_icon = get_icon, free_all = free_all}
end

function window:_setup_icon_api()
	self._icon_api = {}
	self:_add_icon_api'big'
	self:_add_icon_api'small'
end

function window:_call_icon_api(which, name, ...)
	return self._icon_api[which][name](...)
end

function window:_free_icon_api()
	self.win.icon = nil --must release the old ones first so we can free them.
	self.win.small_icon = nil --must release the old ones first so we can free them.
	self:_call_icon_api('big', 'free_all')
	self:_call_icon_api('small', 'free_all')
end

function window:icon_bitmap(which)
	which = whicharg(which)
	return self:_call_icon_api(which, 'get_bitmap')
end

function window:invalidate_icon(which)
	--TODO: both methods below work equally bad. The taskbar icon is not updated :(
	which = whicharg(which)
	self.frontend:_backend_repaint_icon(which)
	if false then
		winapi.SendMessage(self.win.hwnd, 'WM_SETICON',
			which == 'small' and winapi.ICON_SMALL or winapi.ICON_BIG,
			self:_call_icon_api(which, 'get_icon'))
	else
		local name = which == 'small' and 'small_icon' or 'icon'
		self.win[name] = nil --must release the old one first so we can free it.
		self.win[name] = self:_call_icon_api(which, 'get_icon')
	end
end

--file chooser ---------------------------------------------------------------

require'winapi.filedialogs'

--given a list of file types eg. {'gif', ...} make a list of filters
--to pass to open/save dialog functions.
--we can't allow wildcards and custom text because OSX doesn't (so english only).
local function make_filters(filetypes)
	if not filetypes then
		--like in OSX, no filetypes means all filetypes.
		return {'All Files', '*.*'}
	end
	local filter = {}
	for i,ext in ipairs(filetypes) do
		table.insert(filter, ext:upper() .. ' Files')
		table.insert(filter, '*.' .. ext:lower())
	end
	return filter
end

function app:opendialog(opt)
	local filter = make_filters(opt.filetypes)

	local flags = opt.multiselect
		and bit.bor(winapi.OFN_ALLOWMULTISELECT, winapi.OFN_EXPLORER) or 0

	local ok, info = winapi.GetOpenFileName{
		title = opt.title,
		filter = filter,
		filter_index = 1, --first in list is default, like OSX
		flags = flags,
	}

	if not ok then return end
	return winapi.GetOpenFileNamePaths(info)
end

function app:savedialog(opt)
	local filter = make_filters(opt.filetypes)

	local ok, info = winapi.GetSaveFileName{
		title = opt.title,
		filter = filter,
		--default is first in list (not optional in OSX)
		filter_index = 1,
		--append filetype automatically (not optional in OSX)
		--if user types in a file extension, the filetype will still be appended
		--but only if it's not in the list of accepted filetypes.
		--fortunately, this matches OSX behavior exactly.
		default_ext = opt.filetypes and opt.filetypes[1],
		filepath = opt.filename,
		initial_dir = opt.path,
		flags = 'OFN_OVERWRITEPROMPT', --like in OSX
	}

	if not ok then return end
	return info.filepath
end

--clipboard ------------------------------------------------------------------

require'winapi.clipboard'
require'winapi.shellapi'

function app:clipboard_empty(format)
	return winapi.CountClipboardFormats() == 0
end

local formats = {
	[winapi.CF_UNICODETEXT] = 'text',
	[winapi.CF_HDROP] = 'files',
	[winapi.CF_DIB] = 'bitmap',
	[winapi.CF_DIBV5] = 'bitmap',
	[winapi.CF_BITMAP] = 'bitmap',
}

local function with_clipboard(func)
	if not winapi.OpenClipboard() then
		return
	end
	local ok, ret = glue.pcall(func)
	winapi.CloseClipboard()
	if not ok then error(ret, 2) end
	return ret
end

function app:clipboard_formats()
	return with_clipboard(function()
		local names = winapi.GetClipboardFormatNames()
		local t,dupes = {},{}
		for i=1,#names do
			local format = formats[names[i]]
			if format and not dupes[format] then
				dupes[format] = true
				t[#t+1] = format
			end
		end
		return t
	end)
end

function app:get_clipboard(format)
	return with_clipboard(function()
		if format == 'text' then
			return winapi.GetClipboardText()
		elseif format == 'files' then
			return winapi.GetClipboardFiles()
		elseif format == 'bitmap' then
			--NOTE: Windows synthesizes bitmap formats so we can always get
			--a CF_DIBV5 even if only CF_BITMAP or CF_DIB is listed.
			return winapi.GetClipboardDataBuffer('CF_DIBV5', function(buf, sz)

				local info = ffi.cast('BITMAPV5HEADER*', buf)

				--check if format is supported. palette formats are not supported!
				if info.bV5BitCount ~= 32 and info.bV5BitCount ~= 24 then return end
				if info.bV5Compression ~= winapi.BI_BITFIELDS
					and info.bV5Compression ~= winapi.BI_RGB then return end
				if info.bV5ProfileSize > 0 then return end

				--get bitmap metadata.
				local w = info.bV5Width
				local h = math.abs(info.bV5Height)
				local bpp = info.bV5BitCount
				local format = bpp == 32 and 'bgra8' or 'bgr8'
				local stride = bitmap.aligned_stride(w * bpp / 8)
				local size = stride * h
				local bottom_up = info.bV5Height >= 0 or nil

				--find the pixels: work around a winapi bug where there's
				--sometimes a 12 bytes gap between the header and the pixels.
				local gap = info.bV5Compression == winapi.BI_BITFIELDS
					and (sz - info.bV5Size) > w * h * 4
					and 12 or 0
				local data = ffi.cast('void*', ffi.cast('char*', buf) + info.bV5Size + gap)

				--create a temporary bitmap.
				local bmp = {w = w, h = h, format = format, stride = stride,
					size = size, data = data, bottom_up = bottom_up}

				--copy the bitmap because we don't own the memory, and also
				--because it may need to be converted to bgra8.
				return bitmap.copy(bmp, 'bgra8', false)
			end)
		end
	end)
end

function app:set_clipboard(t)
	return with_clipboard(function()
		winapi.EmptyClipboard()
		for i,t in ipairs(t) do
			local data, format = t.data, t.format
			if format == 'text' then
				winapi.SetClipboardText(data)
			elseif format == 'files' then
				winapi.SetClipboardFiles(data)
			elseif format == 'bitmap' then
				--NOTE: Windows synthesizes bitmap formats so it's enough to put
				--a CF_DIBV5 bitmap to be able to get a CF_BITMAP or CF_DIB.
				local bmp = data
				local data_offset = ffi.sizeof'BITMAPV5HEADER'
				local dib_size = data_offset + bmp.size
				winapi.SetClipboardDataBuffer('CF_DIBV5', nil, dib_size, function(buf)
					--make a packed DIB and copy the pixels to it.
					local bi = dib_header(bmp.w, bmp.h, ffi.cast('BITMAPV5HEADER*', buf))
					local data_ptr = ffi.cast('uint8_t*', buf) + data_offset
					ffi.copy(data_ptr, bmp.data, bmp.size)
				end)
			end
		end
		return true
	end) or false
end

--buttons --------------------------------------------------------------------



if not ... then require'nw_test' end

return nw
