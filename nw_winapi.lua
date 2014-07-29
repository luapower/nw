--native widgets winapi backend (Cosmin Apreutesei, public domain).
local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local winapi = require'winapi'
require'winapi.time'
require'winapi.spi'
require'winapi.sysinfo'
require'winapi.systemmetrics'
require'winapi.monitor'
require'winapi.windowclass'
require'winapi.mouse'
require'winapi.keyboard'
require'winapi.rawinput'
require'winapi.gdi'
require'winapi.cursor'

local function unpack_rect(rect)
	return rect.x, rect.y, rect.w, rect.h
end

local nw = {name = 'winapi'}

--os version -----------------------------------------------------------------

function nw:os(ver)
	local vinfo = winapi.GetVersionEx()
	return string.format('Windows %d.%d.SP%d.%d',
		vinfo.dwMajorVersion, vinfo.dwMinorVersion,
		vinfo.wServicePackMajor, vinfo.wServicePackMinor)
end

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
	self:_activate_started()
	winapi.MessageLoop(function(msg)
		--print(winapi.findname('WM_', msg.message))
	end)
end

function app:stop()
	winapi.PostQuitMessage()
end

--time -----------------------------------------------------------------------

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

local win_map = {} --win->window

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local framed = t.frame == 'normal'

	self.win = Window{
		--state
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		visible = false,
		state = t.maximized and 'maximized',
		--frame
		title = t.title,
		border = framed,
		frame = framed,
		window_edge = framed,
		layered = t.frame == 'transparent',
		--behavior
		topmost = t.topmost,
		minimize_button = t.minimizable,
		maximize_button = t.maximizable,
		noclose = not t.closeable,
		sizeable = framed and t.resizeable,
		receive_double_clicks = false, --we do our own double-clicking
	}

	win_map[self.win] = self.frontend

	self.win.__wantallkeys = true --don't let IsDialogMessage() filter out our precious WM_CHARs

	self.win.frontend = frontend
	self.win.backend = self
	self.win.app = app

	self.frontend.backend = self

	self:reset_keystate()

	--init mouse state
	self:_updatemouse()

	--start tracking mouse leave
	winapi.TrackMouseEvent{hwnd = self.win.hwnd, flags = winapi.TME_LEAVE}

	self._fullscreen = t.fullscreen
	self._show_minimized = t.minimized
	self._show_fullscreen = t.fullscreen
	if self._show_fullscreen then
		--until shown, we need this for maximized()
		self._fs = {maximized = self.win.maximized}
	end

	return self
end

--closing --------------------------------------------------------------------

function window:forceclose()
	self.win._forceclose = true --because win:close() calls on_close().
	self.win:close()
end

function Window:on_close()
	if not self._forceclose and not self.frontend:_backend_closing() then
		return 0
	end
end

function Window:on_destroy()
	self.frontend:_backend_closed()
	win_map[self] = nil
end

--activation -----------------------------------------------------------------

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

function app:_activate_started()
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

function window:_activated()
	self.app:_activated()
	self.app._last_active_window = self --for the next app:activate()
	self:reset_keystate()
	if not self.app._started then
		--defer activation if the app is not started, to emulate OSX behavior.
		self.app._activate_window = self
	elseif not self._active then --ignore duplicate events.
		self._active = true
		self.frontend:_backend_activated()
	end
end

function window:_deactivated()
	self:reset_keystate()
	if not self.app._started then
		--clear deferred activation if the app is not started, to emulate OSX behavior.
		self.app._activate_window = nil
	elseif self._active then --ignore duplicate events.
		self._active = false
		self.frontend:_backend_deactivated()
	end
end

function app:activate()
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
	--if the app is inactive, this doesn't activate the window,
	--so we want to set _last_active_window for a later call to app:activate(),
	--which will flash this window's button.
	self.app._last_active_window = self
	self.win:activate()
end

function window:active()
	--return the active flag only if the app is active, to emulate OSX behavior.
	return self.app._active and self.win.active or false
end

--this event is received when the titlebar is activated.
--on_activate() is received even when the app is inactive and the window doesn't actually activate.
function Window:on_nc_activate()
	self.backend:_activated()
end

function Window:on_deactivate()
	self.backend:_deactivated()
end

function Window:on_deactivate_app()
	self.app:_deactivated()
end

--state ----------------------------------------------------------------------

function window:show()
	if self._show_minimized then
		if self._show_fullscreen then
			self:_enter_fullscreen(true)
		else
			self:minimize()
		end
	else
		if self._show_fullscreen then
			self:_enter_fullscreen()
		else
			self.win:show()
		end
	end
end

function window:hide()
	self.win:hide()
end

function window:visible()
	return self.win.visible
end

function window:minimize()
	self._show_minimized = nil
	self.win:minimize()
end

function window:_maximize()
	self._show_minimized = nil
	self._show_fullscreen = nil
	self.win:maximize()
	--frameless windows maximize to the entire screen, covering the taskbar. fix that.
	if not self.win.frame then
		local t = self:display()
		self.win:move(t:client_rect())
	end
end
function window:maximize()
	if self:fullscreen() then
		self:_exit_fullscreen(true)
	else
		self:_maximize()
	end
end

function window:restore()
	if self:fullscreen() and not self:minimized() then
		self:_exit_fullscreen()
	else
		self._show_minimized = nil
		self.win:restore()
	end
end

function window:shownormal()
	self._show_minimized = nil
	self.win:shownormal()
end

function window:_enter_fullscreen(to_minimized)
	self._show_fullscreen = nil

	self._fs = {
		maximized = self.win.maximized,
		normal_rect = self.win.normal_rect,
		frame = self.win.frame,
		sizeable = self.win.sizeable,
	}

	self.win.visible = false
	self.win.frame = false
	self.win.border = false
	self.win.sizeable = false
	local d = self:display()
	local r = winapi.RECT(d.x, d.y, d.x + d.w, d.y + d.h)
	if to_minimized then
		self.win.normal_rect = r
		assert(not self.win.visible)
		self.restore_to_maximized = false
		assert(not self.win.visible)
		self.win:minimize()
	else
		self.win.normal_rect = r
		if not self.win.visible then
			self.win:shownormal()
		end
	end

	self._fullscreen = true
end

function window:_exit_fullscreen(to_maximized)
	self.win.visible = false
	self.win.frame = self._fs.frame
	self.win.border = self._fs.frame
	self.win.sizeable = self._fs.sizeable
	self.win.normal_rect = self._fs.normal_rect
	if to_maximized or self._fs.maximized then
		self:_maximize()
	else
		self.win:shownormal()
	end

	self._fullscreen = false
	self._noevents = nil
end

function window:minimized()
	if self._show_minimized then
		return self._show_minimized
	end
	return self.win.minimized
end

function window:maximized()
	if self.win.minimized then
		return self.win.restore_to_maximized
	elseif self._fullscreen then
		return self._fs.maximized
	end
	return self.win.maximized
end

function window:fullscreen(fullscreen)
	if fullscreen ~= nil then
		if fullscreen ~= self._fullscreen then
			if fullscreen then
				self:_enter_fullscreen()
			else
				self:_exit_fullscreen()
			end
		end
	else
		return self._fullscreen
	end
end

--positioning ----------------------------------------------------------------

function window:get_frame_rect()
	if self._fullscreen then
		return unpack_rect(self._fs.normal_rect)
	else
		return unpack_rect(self.win.normal_rect)
	end
end

function window:set_frame_rect(x, y, w, h)
	if self._fullscreen then
		self._fs.normal_rect = RECT(x, y, x + w, y + h)
	else
		self.win:set_normal_rect(x, y, x + w, y + h)
	end
end

function window:client_rect()
	return unpack_rect(self.win.client_rect)
end

function window:magnets()
	local t = {} --{{x, y, w, h}, ...}
	local rect
	for i,hwnd in ipairs(winapi.EnumChildWindows()) do --front-to-back order assured
		if hwnd ~= self.win.hwnd and winapi.IsVisible(hwnd) then
			rect = winapi.GetWindowRect(hwnd, rect)
			t[#t+1] = {x = rect.x, y = rect.y, w = rect.w, h = rect.h}
		end
	end
	return t
end

function Window:on_begin_sizemove()
	self.app._magnets = nil --clear magnets
	local m = winapi.Windows.cursor_pos
	self.nw_dragpoint_x = m.x - self.x
	self.nw_dragpoint_y = m.y - self.y
	self.nw_start_resize = true
end

function Window:on_end_sizemove()
	self.nw_start_resize = false
	self.frontend:_backend_end_resize()
end

function Window:frame_changing(how, rect)
	local dx = self.nw_dragpoint_x
	local dy = self.nw_dragpoint_y
	if self.nw_start_resize then
		self.nw_start_resize = false
		self.frontend:_backend_start_resize(how)
	end
	if how == 'move' then
		--preserve the initial drag point, regardless of how the coordinates
		--are adjusted on each event.
		--this also emulates the default OSX behavior.
		local m = winapi.Windows.cursor_pos
		rect.x = m.x - dx
		rect.y = m.y - dy
	end
	local x, y, w, h = self.frontend:_backend_resizing(how, unpack_rect(rect))
	rect.x = x or rect.x
	rect.y = y or rect.y
	rect.w = w or rect.w
	rect.h = h or rect.h
end

function Window:on_moving(rect)
	self:frame_changing('move', rect)
	return true
end

function Window:on_resizing(how, rect)
	self:frame_changing(how, rect)
end

function Window:on_moved()
	if self.layered then
		--TODO
		--self.win_pos.x = self.x
		--self.win_pos.y = self.y
		self:invalidate()
	end
end

function Window:on_resized(flag)
	if flag == 'minimized' then
		self.frontend:_backend_resized'minimize'
	elseif flag == 'maximized' then
		self:invalidate()
		self.frontend:_backend_resized'maximize'
	elseif flag == 'restored' then
		self:invalidate()
		self.frontend:_backend_resized'restore'
	end
end

function window:mouse_pos()
	return winapi.GetMessagePos()
end

function Window:on_pos_changed(info)
	--self.frontend:_event'frame_changed'
end

--displays -------------------------------------------------------------------

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

function app:main_display()
	return self:_display(winapi.MonitorFromPoint(nil, 'MONITOR_DEFAULTTOPRIMARY'))
end

function app:display_count()
	return winapi.GetSystemMetrics'SM_CMONITORS'
end

function window:display()
	return self.app:_display(self.win.monitor)
end

function Window:on_display_change(x, y, bpp)
	self.app.frontend:_backend_displays_changed()
end

--cursors --------------------------------------------------------------------

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

--frame ----------------------------------------------------------------------

function window:title(title)
	if title then
		self.win.title = title
	else
		return self.win.title
	end
end

function window:topmost(topmost)
	if topmost ~= nil then
		self.win.topmost = topmost
	else
		return self.win.topmost
	end
end

--keyboard -------------------------------------------------------------------

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
	[winapi.VK_PAUSE]    = 'break',       --win keyboard; mapped to 'F15' on mac

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

local keycodes  = glue.index(keynames)

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

local keystate
local repeatstate
local altgr

function window:reset_keystate()
	keystate = {}
	repeatstate = {}
	altgr = nil
end

function Window:setkey(vk, flags, down)
	if vk == winapi.VK_SHIFT then
		return --shift is handled using raw input because we don't get key up on shift if the other shift is pressed!
	end
	if winapi.IsAltGr(vk, flags) then
		altgr = true --next key is 'ralt' which we'll make into 'altgr'
		return
	end
	local name = keynames_ext[flags.extended_key][vk] or keynames[vk]
	if altgr then
		altgr = nil
		if name == 'ralt' then
			name = 'altgr'
		end
	end
	if not keycodes[name] then --save the state of this key because we can't get it with GetKeyState()
		keystate[name] = down
	end
	if self.app.frontend:ignore_numlock() then --ignore the state of the numlock key (for games)
		name = ignore_numlock_keys[name] or name
	end
	return name
end

--prevent repeating these keys to emulate OSX behavior, and also because flags.prev_key_state
--doesn't work for them.
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
function Window:WM_SYSCOMMAND(sc, char_code)
	if sc == winapi.SC_KEYMENU and char_code == 0 then
		return 0
	end
end

local toggle_keys = glue.index{'capslock', 'numlock', 'scrolllock'}

function window:key(name)
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

	--handle shift key presses
	local vk = raw.data.keyboard.VKey
	if vk == winapi.VK_SHIFT then
		vk = winapi.MapVirtualKey(raw.data.keyboard.MakeCode, winapi.MAPVK_VSC_TO_VK_EX)
		local key = vk == winapi.VK_LSHIFT and 'lshift' or 'rshift'
		if bit.band(raw.data.keyboard.Flags, 1) == 0 then --keydown
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
	end
end

--[[
local function memoize(func)
	local cache = setmetatable({}, {__mode = 'v'})
	return function(k)
		local v = cache[k]
		if v == nil then
			v = func(k)
			cache[k] = v
		end
		return v
	end
end

local parse_shortcut = memoize(function(s) --'ctrl+shift+F10' -> {'ctrl', 'shift', 'F10'}
	--escape '+'
	local esc
	if s:find('num+', nil, true) then esc = true; s = s:gsub('num%+', 'num#') end
	if s:find('++',   nil, true) then esc = true; s = s:gsub('%+%+', '+#') end
	if s:find'^%+'               then esc = true; s = s:gsub('^%+', '#') end
	local t = {}
	for s in glue.gsplit(s, '+', nil, true) do
		if esc then s = s:gsub('#', '+') end --unescape
		t[#t+1] = s
	end
	return t
end)

local function get_key_combination(s) --'name+name+...'
	if s == '' then return end
	for i,s in ipairs(parse_shortcut(s)) do
		if s == '' then return end
		local down = get_key(s)
		if not down then return down end
	end
	return true
end

function window:key(s)
	return get_key_combination(s)
end
]]

--mouse ----------------------------------------------------------------------

function app:double_click_time() --milliseconds
	return winapi.GetDoubleClickTime()
end

function app:double_click_target_area()
	local w = winapi.GetSystemMetrics(winapi.SM_CXDOUBLECLK)
	local h = winapi.GetSystemMetrics(winapi.SM_CYDOUBLECLK)
	return w, h
end

--TODO: get lost mouse events http://blogs.msdn.com/b/oldnewthing/archive/2012/03/14/10282406.aspx

local function unpack_buttons(b)
	return b.lbutton, b.rbutton, b.mbutton, b.xbutton1, b.xbutton2
end

function window:_updatemouse()
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
	cairoview = 'nw_winapi_cairoview',
	glview    = 'nw_winapi_glview',
})

function window:invalidate()
	self.backend:invalidate()
end

--menus ----------------------------------------------------------------------

local menu = {}

function app:menu()
	return menu:_new(winapi.Menu())
end

function window:menu()
	if not self._menu then
		local menubar = winapi.MenuBar()
		self.win.menu = menubar
		self._menu = menu:_new(menubar)
	end
	return self._menu
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
	self.winmenu.items:set(index, menuitem(args, self.winmenu.type))
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

function window:popup(menu, x, y)
	menu.backend.winmenu:popup(self.win, x, y)
end

--buttons --------------------------------------------------------------------



if not ... then require'nw_test' end

return nw
