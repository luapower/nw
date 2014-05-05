--native widgets winapi backend
local winapi = require'winapi'
require'winapi.windowclass'
require'winapi.spi'
require'winapi.mouse'
require'winapi.keyboard'
require'winapi.time'
require'winapi.systemmetrics'
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
	--WM_QUIT from the outside (improbable)
	self:_backend_quit() --calls quit() which exits the process or returns which means refusal to quit.
	self:run()
end

function app:quit()
	--process any left-over messages and exit
	winapi.PostQuitMessage()
	winapi.ProcessMessages()
	os.exit(self.delegate:_backend_exit())
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

function app:double_click_time() --milliseconds
	return winapi.GetDoubleClickTime()
end

function app:double_click_target_area()
	local w = winapi.GetSystemMetrics(winapi.SM_CXDOUBLECLK)
	local h = winapi.GetSystemMetrics(winapi.SM_CYDOUBLECLK)
	return w, h
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

	self._minimized = t.minimized
	self._fullscreen = t.fullscreen

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

--focus

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
	if self._minimized then
		self:minimize()
		self._minimized = nil
	end
	self.win:show()
end

function window:minimize()
	self._minimized = nil
	self.win:minimize()
end

function window:maximize()
	self._minimized = nil
	self.win:maximize()
	--frameless windows maximize to the entire screen, covering the taskbar. fix that.
	if not self.win.frame then
		local t = self:display()
		self.win:move(t.client_x, t.client_y, t.client_w, t.client_h)
	end
end

function window:restore()
	self._minimized = nil
	self.win:restore()
end

function window:shownormal()
	self._minimized = nil
	self.win:shownormal()
end

function window:enter_fullscreen()
	self._fs = {
		state = self.win.state,
		normal_rect = self.win.normal_rect,
		titlebar = self.win.titlebar,
		sizeable = self.win.sizeable,
	}
	self.win.visible = false
	self.win.normal_rect = winapi.GetMonitorInfo(self:monitor()).monitor_rect
	self.win.titlebar = false
	self.win.sizeable = false
	self.win.state = 'normal'
	self.win.visible = true
	self._fullscreen = true
end

function window:leave_fullscreen()
	self.win.visible = false
	self.win.normal_rect = self._fs.normal_rect
	self.win.titlebar = self._fs.titlebar
	self.win.sizeable = self._fs.sizeable
	self.win.visible = true
	self.win.state = self._fs.state
	--frameless windows maximize to the entire screen, covering the taskbar. fix that.
	if self.win.state == 'maximized' and not self.win.titlebar then
		self.win.rect = winapi.GetMonitorInfo(self:monitor()).work_rect
	end
	self._fullscreen = false
end

function window:visible()
	return self.win.visible
end

function window:minimized()
	if self._minimized then
		return self._minimized
	end
	return self.win.minimized
end

function window:maximized()
	if self.win.minimized then
		return self.win.restore_to_maximized
	end
	return self.win.maximized
end

function window:fullscreen()
	return self._fullscreen
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

--winapi keycodes. key codes for 0-9 and A-Z keys are ascii codes.
local keynames = {
	[0x08] = 'backspace',[0x09] = 'tab',      [0x0d] = 'enter',    [0x10] = 'shift',    [0x11] = 'ctrl',
	[0x12] = 'alt',      [0x13] = 'break',    [0x14] = 'capslock', [0x1b] = 'esc',      [0x20] = 'space',
	[0x21] = 'pageup',   [0x22] = 'pagedown', [0x23] = 'end',      [0x24] = 'home',     [0x25] = 'left',
	[0x26] = 'up',       [0x27] = 'right',    [0x28] = 'down',     [0x2c] = 'printscreen',
	[0x2d] = 'insert',   [0x2e] = 'delete',   [0x60] = 'num0',     [0x61] = 'num1',     [0x62] = 'num2',
	[0x63] = 'num3',     [0x64] = 'num4',     [0x65] = 'num5',     [0x66] = 'num6',     [0x67] = 'num7',
	[0x68] = 'num8',     [0x69] = 'num9',     [0x6a] = 'num*',     [0x6b] = 'num+',     [0x6d] = 'num-',
	[0x6e] = 'num.',     [0x6f] = 'num/',     [0x70] = 'F1',       [0x71] = 'F2',       [0x72] = 'F3',
	[0x73] = 'F4',       [0x74] = 'F5',       [0x75] = 'F6',       [0x76] = 'F7',       [0x77] = 'F8',
	[0x78] = 'F9',       [0x79] = 'F10',      [0x7a] = 'F11',      [0x7b] = 'F12',      [0x90] = 'numlock',
	[0x91] = 'scrolllock',
	--varying by keyboard
	[0xba] = ';',        [0xbb] = '+',        [0xbc] = ',',        [0xbd] = '-',        [0xbe] = '.',
	[0xbf] = '/',        [0xc0] = '`',        [0xdb] = '[',        [0xdc] = '\\',       [0xdd] = ']',
	[0xde] = "'",
	--windows keyboard
	[0xff] = 'lwin',     [0x5c] = 'rwin',     [0x5d] = 'menu',
	--query only
	[0xa0] = 'lshift',   [0xa1] = 'rshift',   [0xa2] = 'lctrl',    [0xa3] = 'rctrl',    [0xa4] = 'lalt',
	[0xa5] = 'ralt',
}

local B = string.byte

local function keyname(vk)
	return ((vk >= B'0' and vk <= B'9') or (vk >= B'A' and vk <= B'Z'))
				and string.char(vk) or keynames[vk] or vk
end

local keycodes = glue.index(keynames)

local function keycode(name)
	return keycodes[name] or
		(type(name) == 'string' and
		  ((B(name) >= B'0' and B(name) <= B'9') or
		   (B(name) >= B'A' and B(name) <= B'Z')) and B(name)
		) or name
end

function Window:on_key_down(vk, flags)
	local key = keyname(vk)
	if not flags.prev_key_state then
		self.delegate:_backend_keydown(key)
	end
	self.delegate:_backend_keypress(key)
end

function Window:on_key_up(vk)
	self.delegate:_backend_keyup(keyname(vk))
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
	local down, toggled = winapi.GetKeyState(assert(keycode(key), 'invalid key name'))
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
		self.delegate:_backend_mousemove(x, y, unpack_buttons(buttons))
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
	delta = math.floor(delta / 120) --note: when scrolling backwards I get -119 instead of -120
	self:setmouse(x, y, buttons)
	self.delegate:_backend_mousewheel(delta)
end

function Window:on_mouse_hwheel(x, y, buttons, delta)
	delta = delta / 120
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
	--print('create_surface', w, h)
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

