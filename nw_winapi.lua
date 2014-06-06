--native widgets winapi backend
local winapi = require'winapi'
require'winapi.windowclass'
require'winapi.spi'
require'winapi.mouse'
require'winapi.keyboard'
require'winapi.time'
require'winapi.systemmetrics'
require'winapi.spi'
require'winapi.gdi'
require'winapi.monitor'
local glue = require'glue'
local ffi = require'ffi'
local box2d = require'box2d'

local function unpack_rect(rect)
	return rect.x, rect.y, rect.w, rect.h
end

local backend = {}

function backend:app(delegate)
	return self.app_class:new(delegate)
end

--app class

local app = {}
backend.app_class = app

function app:new(delegate)
	return glue.inherit({delegate = delegate}, self)
end

--run/quit

function printmsg(msg)
	--print(winapi.findname('WM_', msg.message))
end

function app:run()
	winapi.MessageLoop(printmsg)
end

function app:stop()
	winapi.PostQuitMessage()
end

--timers

function app:runafter(seconds, func)
	self.timer_cb = self.timer_cb or ffi.cast('TIMERPROC', function(hwnd, wm_timer, id, ellapsed_ms)
		local func = self.timers[id]
		self.timers[id] = nil
		winapi.KillTimer(nil, id)
		func()
	end)
	local id = winapi.SetTimer(nil, 0, seconds * 1000, self.timer_cb)
	self.timers = self.timers or {}
	self.timers[id] = func
end

--activation

function app:activate()
	--TODO
end

--displays

local function display(monitor)
	local ok, info = pcall(winapi.GetMonitorInfo, monitor)
	if not ok then return end
	return {
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
		table.insert(displays, display(monitors[i])) --invalid displays are skipped
	end
	return displays
end

function app:main_display()
	return display(winapi.MonitorFromPoint(nil, winapi.MONITOR_DEFAULTTOPRIMARY))
end

--system info

function app:double_click_time() --milliseconds
	return winapi.GetDoubleClickTime()
end

function app:double_click_target_area()
	local w = winapi.GetSystemMetrics(winapi.SM_CXDOUBLECLK)
	local h = winapi.GetSystemMetrics(winapi.SM_CYDOUBLECLK)
	return w, h
end

function app:wheel_scroll_chars()
	self.wsc_buf = self.wsc_buf or ffi.new'UINT[1]'
	winapi.SystemParametersInfo(winapi.SPI_GETWHEELSCROLLCHARS, 0, self.wsc_buf)
	return self.wsc_buf[0]
end

function app:wheel_scroll_lines()
	self.wsl_buf = self.wsl_buf or ffi.new'UINT[1]'
	winapi.SystemParametersInfo(winapi.SPI_GETWHEELSCROLLLINES, 0, self.wsl_buf)
	return self.wsl_buf[0]
end

--time

function app:time()
	return winapi.QueryPerformanceCounter().QuadPart
end

function app:timediff(start_time, end_time)
	self.qpf = self.qpf or tonumber(winapi.QueryPerformanceFrequency().QuadPart)
	local interval = end_time - start_time
	return tonumber(interval * 1000) / self.qpf --milliseconds
end

function app:window(delegate, t)
	return self.window_class:new(self, delegate, t)
end

--window class

local window = {}
app.window_class = window

local Window = winapi.subclass({}, winapi.Window)

function window:new(app, delegate, t)
	self = glue.inherit({app = app, delegate = delegate}, self)

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

	self.win.__wantallkeys = true --don't let IsDialogMessage() filter out our precious WM_CHARs
	self.win.delegate = delegate
	self.win.app = self.app

	--init mouse state
	local m = self.delegate.mouse
	local pos = self.win.cursor_pos
	m.x = pos.x
	m.y = pos.y
	m.left = winapi.GetKeyState(winapi.VK_LBUTTON)
	m.middle = winapi.GetKeyState(winapi.VK_MBUTTON)
	m.right = winapi.GetKeyState(winapi.VK_RBUTTON)
	m.xbutton1 = winapi.GetKeyState(winapi.VK_XBUTTON1)
	m.xbutton2 = winapi.GetKeyState(winapi.VK_XBUTTON2)
	m.inside = box2d.hit(m.x, m.y, unpack_rect(self.win.client_rect))

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

--lifetime

function window:close()
	self.win._forceclose = true
	self.win:close() --calls on_close() hence _forceclose
end

function Window:on_close()
	if not self._forceclose and not self.delegate:_backend_closing() then
		return 0
	end
end

function Window:on_destroy()
	self.delegate:_backend_closed()
	self:free_surface()
end

--activation

function window:activate()
	self.win:activate()
end

function window:active()
	return self.win.active
end

function Window:on_activate()
	self.delegate:_backend_activated()
end

function Window:on_deactivate()
	self.delegate:_backend_deactivated()
end

function Window:on_activate_app()
	self.delegate.app:_backend_activated()
end

function Window:on_deactivate_app()
	self.delegate.app:_backend_deactivated()
end

--state

function window:hide()
	self.win:hide()
end

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
		self.win:move(t.client_x, t.client_y, t.client_w, t.client_h)
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
	self._noevents = true
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
	self._noevents = nil
end

function window:_exit_fullscreen(to_maximized)
	self._noevents = true

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

function window:visible()
	return self.win.visible
end

function window:minimized()
	if self._show_minimized then
		return self._show_minimized
	end
	return self.win.minimized
end

function window:maximized()
	if self.win.visible and self.win.minimized then
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

--positioning

function window:frame_rect(x, y, w, h)
	if x then
		if self._fullscreen then
			self._fs.normal_rect = RECT(x, y, x + w, y + h)
		else
			self.win:set_normal_rect(x, y, x + w, y + h)
		end
	else
		if self._fullscreen then
			return unpack_rect(self._fs.normal_rect)
		else
			return unpack_rect(self.win.normal_rect)
		end
	end
end

function Window:frame_changing(how, rect)
	local x, y, w, h = self.delegate:_backend_resizing(how, unpack_rect(rect))
	rect.x = x or rect.x
	rect.y = y or rect.y
	rect.w = w or rect.w
	rect.h = h or rect.h
end

function Window:on_moving(rect)
	self:frame_changing('move', rect)
end

function Window:on_resizing(how, rect)
	self:frame_changing(how, rect)
end

function Window:on_moved()
	if self.layered then
		self.win_pos.x = self.x
		self.win_pos.y = self.y
		self.delegate:invalidate()
	end
end

function Window:resized()
	self:free_surface()
	self.delegate:invalidate()
end

function Window:on_resized(flag)
	if flag == 'minimized' then
		self.delegate:_backend_minimized()
	elseif flag == 'maximized' then
		self:resized()
		self.delegate:_backend_maximized()
	elseif flag == 'restored' then
		self:resized()
		self.delegate:_backend_resized()
	end
end

function Window:on_pos_changed(info)
	--self.delegate:_event'frame_changed'
end

function window:display()
	return display(self.win.monitor)
end

--displays

function Window:on_display_change(x, y, bpp)
	self.delegate.app:_backend_displays_changed()
end

--frame

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

--keyboard

local keycodes = {

	[';'] = winapi.VK_OEM_1, --US only
	['+'] = winapi.VK_OEM_PLUS,
 	[','] = winapi.VK_OEM_COMMA,
	['-'] = winapi.VK_OEM_MINUS,
	['.'] = winapi.VK_OEM_PERIOD,
	['/'] = winapi.VK_OEM_2, --US only
	['`'] = winapi.VK_OEM_3, --US only
	['['] = winapi.VK_OEM_4, --US only
	['\\'] = winapi.VK_OEM_5, --US only
	[']'] = winapi.VK_OEM_6, --US only
	['\''] = winapi.VK_OEM_7, --US only

	backspace = winapi.VK_BACK,
	tab       = winapi.VK_TAB,
	enter     = winapi.VK_RETURN,
	space     = winapi.VK_SPACE,
	esc       = winapi.VK_ESCAPE,

	F1 = winapi.VK_F1,
	F2 = winapi.VK_F2,
	F3 = winapi.VK_F3,
	F4 = winapi.VK_F4,
	F5 = winapi.VK_F5,
	F6 = winapi.VK_F6,
	F7 = winapi.VK_F7,
	F8 = winapi.VK_F8,
	F9 = winapi.VK_F9,
	F10 = winapi.VK_F10,
	F11 = winapi.VK_F11, --note: not on osx
	F12 = winapi.VK_F12, --note: not on osx

	lshift = winapi.VK_LSHIFT,
	rshift = winapi.VK_RSHIFT,
	lctrl  = winapi.VK_CONTROL,
	lalt   = winapi.VK_MENU,

	capslock    = winapi.VK_CAPITAL,
	numlock     = winapi.VK_NUMLOCK,
	scrolllock  = winapi.VK_SCROLL, --note: not on osx
	['break']   = winapi.VK_PAUSE,  --note: not on osx
	printscreen = winapi.VK_SNAPSHOT,

	--numpad with numlock on
	numpad0 = winapi.VK_NUMPAD0,
	numpad1 = winapi.VK_NUMPAD1,
	numpad2 = winapi.VK_NUMPAD2,
	numpad3 = winapi.VK_NUMPAD3,
	numpad4 = winapi.VK_NUMPAD4,
	numpad5 = winapi.VK_NUMPAD5,
	numpad6 = winapi.VK_NUMPAD6,
	numpad7 = winapi.VK_NUMPAD7,
	numpad8 = winapi.VK_NUMPAD8,
	numpad9 = winapi.VK_NUMPAD9,
	['numpad.'] = winapi.VK_DECIMAL,

	--numpad with numlock off
	numpadclear     = winapi.VK_CLEAR, --numpad 5 with numlock off
	numpadleft      = winapi.VK_LEFT,
	numpadup        = winapi.VK_UP,
	numpadright     = winapi.VK_RIGHT,
	numpaddown      = winapi.VK_DOWN,
	numpadpageup    = winapi.VK_PRIOR,
	numpadpagedown  = winapi.VK_NEXT,
	numpadend       = winapi.VK_END,
	numpadhome      = winapi.VK_HOME,
	numpadinsert    = winapi.VK_INSERT,
	numpaddelete    = winapi.VK_DELETE,

	--numpad (single function)
	['numpad*'] = winapi.VK_MULTIPLY,
	['numpad+'] = winapi.VK_ADD,
	['numpad-'] = winapi.VK_SUBTRACT,
	['numpad/'] = winapi.VK_DIVIDE,
	numpadenter = winapi.VK_RETURN,

	--multimedia
	mute = winapi.VK_VOLUME_MUTE,
	volumedown = winapi.VK_VOLUME_DOWN,
	volumeup = winapi.VK_VOLUME_UP,

	--windows keyboard
	lwin = 0xff,
	rwin = winapi.VK_RWIN,
	menu = winapi.VK_APPS,
}

--key codes for 0-9 and A-Z keys are ascii codes

for ascii = string.byte('0'), string.byte('9') do
	keycodes[string.char(ascii)] = ascii
end

for ascii = string.byte('A'), string.byte('Z') do
	keycodes[string.char(ascii)] = ascii
end

--key codes when the extended_key flag is set

local ext_keycodes = {

	rctrl = winapi.VK_CONTROL,
	ralt  = winapi.VK_MENU,

	left  = winapi.VK_LEFT,
	up    = winapi.VK_UP,
	right = winapi.VK_RIGHT,
	down  = winapi.VK_DOWN,

	pageup   = winapi.VK_PRIOR,
	pagedown = winapi.VK_NEXT,
	['end']  = winapi.VK_END,
	home     = winapi.VK_HOME,
	insert   = winapi.VK_INSERT,
	delete   = winapi.VK_DELETE,
}

--translation of keys so that numlock doesn't matter
local numlock_on_keys = {
	numpadleft      = 'numpad4',
	numpadup        = 'numpad8',
	numpadright     = 'numpad6',
	numpaddown      = 'numpad2',
	numpadpageup    = 'numpad9',
	numpadpagedown  = 'numpad3',
	numpadend       = 'numpad1',
	numpadhome      = 'numpad7',
	numpadinsert    = 'numpad0',
	numpaddelete    = 'numpad.',
}

local keynames = glue.index(keycodes)
local ext_keynames = glue.index(ext_keycodes)

local function keyname(vk, flags)
	if vk == winapi.VK_SHIFT then
		vk = winapi.MapVirtualKey(flags.scan_code, winapi.MAPVK_VSC_TO_VK_EX)
	end
	local key = flags.extended_key and ext_keynames[vk] or keynames[vk]
	if not key then return end
	return numlock_on_keys[key] or key
end

function Window:on_key_down(vk, flags)
	local lkey, pkey = keyname(vk, flags)
	if not flags.prev_key_state then
		self.delegate:_backend_keydown(lkey, pkey)
	end
	self.delegate:_backend_keypress(lkey, pkey)
end

function Window:on_key_up(vk, flags)
	local lkey, pkey = keyname(vk, flags)
	self.delegate:_backend_keyup(lkey, pkey)
end

--we get the ALT key with these messages instead
Window.on_syskey_down = Window.on_key_down
Window.on_syskey_up = Window.on_key_up

function Window:on_key_down_char(char)
	self.delegate:_backend_keychar(char)
end

Window.on_syskey_down_char = Window.on_key_down_char

--take control of the ALT and F10 keys
function Window:WM_SYSCOMMAND(sc, char_code)
	if sc == winapi.SC_KEYMENU and char_code == 0 then
		return 0
	end
end

local toggle_key = {capslock = true, numlock = true, scrolllock = true}

function window:key(key) --down[, toggled]
	local down, toggled = winapi.GetKeyState(assert(keycodes[key] or ext_keycodes[key], 'invalid key name'))
	if toggle_key[key] then
		return down, toggled
	end
	return down
end

--mouse

--TODO: get lost mouse events http://blogs.msdn.com/b/oldnewthing/archive/2012/03/14/10282406.aspx

local function unpack_buttons(b)
	return b.lbutton, b.rbutton, b.mbutton, b.xbutton1, b.xbutton2
end

function Window:setmouse(x, y, buttons)

	--set mouse state
	local m = self.delegate.mouse
	m.x = x
	m.y = y
	m.left = buttons.lbutton
	m.right = buttons.rbutton
	m.middle = buttons.mbutton
	m.xbutton1 = buttons.xbutton1
	m.xbutton2 = buttons.xbutton2

	--send hover
	if not m.inside then
		m.inside = true
		winapi.TrackMouseEvent{hwnd = self.hwnd, flags = winapi.TME_LEAVE}
		self.delegate:_backend_mouseenter(x, y, unpack_buttons(buttons))
	end
end

function Window:on_mouse_move(x, y, buttons)
	local m = self.delegate.mouse
	local moved = x ~= m.x or y ~= m.y
	self:setmouse(x, y, buttons)
	if moved then
		self.delegate:_backend_mousemove(x, y)
	end
end

function Window:on_mouse_leave()
	if not self.delegate.mouse.inside then return end
	self.delegate.mouse.inside = false
	self.delegate:_backend_mouseleave()
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
	self:setmouse(x, y, buttons)
	self:capture_mouse()
	self.delegate:_backend_mousedown'left'
end

function Window:on_mbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:capture_mouse()
	self.delegate:_backend_mousedown'middle'
end

function Window:on_rbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:capture_mouse()
	self.delegate:_backend_mousedown'right'
end

function Window:on_xbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:capture_mouse()
		self.delegate:_backend_mousedown'xbutton1'
	end
	if buttons.xbutton2 then
		self:capture_mouse()
		self.delegate:_backend_mousedown'xbutton2'
	end
end

function Window:on_lbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:_backend_mouseup'left'
end

function Window:on_mbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:_backend_mouseup'middle'
end

function Window:on_rbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:_backend_mouseup'right'
end

function Window:on_xbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:uncapture_mouse()
		self.delegate:_backend_mouseup'xbutton1'
	end
	if buttons.xbutton2 then
		self:uncapture_mouse()
		self.delegate:_backend_mouseup'xbutton2'
	end
end

function Window:on_mouse_wheel(x, y, buttons, delta)
	if (delta - 1) % 120 == 0 then --correction for my ms mouse when scrolling back
		delta = delta - 1
	end
	delta = delta / 120 * self.app:wheel_scroll_lines()
	self:setmouse(x, y, buttons)
	self.delegate:_backend_mousewheel(delta)
end

function Window:on_mouse_hwheel(x, y, buttons, delta)
	delta = delta / 120 * self.app:wheel_scroll_chars()
	self:setmouse(x, y, buttons)
	self.delegate:_backend_mousehwheel(delta)
end

--rendering

function window:client_rect()
	return unpack_rect(self.win.client_rect)
end

function window:invalidate()
	if self.win.layered then
		self.win:repaint_surface()
		self.win:update_layered()
	else
		self.win:invalidate()
	end
end

function Window:on_paint(hdc)
	self:repaint_surface()
	winapi.BitBlt(hdc, 0, 0, self.bmp_size.w, self.bmp_size.h, self.bmp_hdc, 0, 0, winapi.SRCCOPY)
end

function Window:WM_ERASEBKGND()
	return false --we draw our own background (prevent flicker)
end

local cairo = require'cairo'

function Window:create_surface()
	if self.bmp then return end
	self.win_pos = winapi.POINT{x = self.x, y = self.y}
	local w, h = self.client_w, self.client_h
	self.bmp_pos = winapi.POINT{x = 0, y = 0}
	self.bmp_size = winapi.SIZE{w = w, h = h}

	local info = winapi.types.BITMAPINFO()
	info.bmiHeader.biSize = ffi.sizeof'BITMAPINFO'
	info.bmiHeader.biWidth = w
	info.bmiHeader.biHeight = -h
	info.bmiHeader.biPlanes = 1
	info.bmiHeader.biBitCount = 32
	info.bmiHeader.biCompression = winapi.BI_RGB
	self.bmp_hdc = winapi.CreateCompatibleDC()
	self.bmp, self.bmp_bits = winapi.CreateDIBSection(self.bmp_hdc, info, winapi.DIB_RGB_COLORS)
	self.old_bmp = winapi.SelectObject(self.bmp_hdc, self.bmp)

	self.blendfunc = winapi.types.BLENDFUNCTION{
		AlphaFormat = winapi.AC_SRC_ALPHA,
		BlendFlags = 0,
		BlendOp = winapi.AC_SRC_OVER,
		SourceConstantAlpha = 255,
	}
	self.pixman_surface = cairo.cairo_image_surface_create_for_data(self.bmp_bits,
									cairo.CAIRO_FORMAT_ARGB32, w, h, w * 4)
	self.pixman_cr = self.pixman_surface:create_context()
end

function Window:free_surface()
	if not self.bmp then return end
	local w, h = self.client_w, self.client_h
	if self.bmp_size.w == w and self.bmp_size.h == h then return end
	self.pixman_cr:free()
	self.pixman_surface:free()
	winapi.SelectObject(self.bmp_hdc, self.old_bmp)
	winapi.DeleteObject(self.bmp)
	winapi.DeleteDC(self.bmp_hdc)
	self.bmp = nil
end

function Window:repaint_surface()
	self:create_surface()
	winapi.GdiFlush()
	self.pixman_cr:set_source_rgba(0, 0, 0, 0)
	self.pixman_cr:set_operator(cairo.CAIRO_OPERATOR_SOURCE)
	self.pixman_cr:paint()
	self.pixman_cr:set_operator(cairo.CAIRO_OPERATOR_OVER)
	self.delegate:_backend_render(self.pixman_cr)
end

function Window:update_layered()
	winapi.UpdateLayeredWindow(self.hwnd, nil, self.win_pos, self.bmp_size, self.bmp_hdc,
										self.bmp_pos, 0, self.blendfunc, winapi.ULW_ALPHA)
end

if not ... then require'nw_test' end

return backend

