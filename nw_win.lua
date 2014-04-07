--native widgets winapi implementation
local winapi = require'winapi'
require'winapi.windowclass'
require'winapi.messageloop'
require'winapi.spi'
require'winapi.mouse'
require'winapi.keyboard'
require'winapi.time'
require'winapi.systemmetrics'
local glue = require'glue'

local function unpack_rect(rect)
	return rect.x, rect.y, rect.w, rect.h
end

--nw impl

local nw = {}

function nw:app()
	return glue.inherit({}, self.app_class)
end

--app impl

local app = {}
nw.app_class = app

function app:run()
	return winapi.MessageLoop()
end

function app:quit()
	winapi.PostQuitMessage()
end

function app:screen_rect()
	return unpack_rect(winapi.GetWindowRect(winapi.GetDesktopWindow()))
end

function app:client_rect()
	local rect = winapi.RECT()
	winapi.SystemParametersInfo(winapi.SPI_GETWORKAREA, 0, rect, 0)
	return unpack_rect(rect)
end

function app:active()
	--
end

function app:double_click_time() --milliseconds
	return winapi.GetDoubleClickTime()
end

function app:double_click_rect_size()
	local w = winapi.GetSystemMetrics(winapi.SM_CXDOUBLECLK)
	local h = winapi.GetSystemMetrics(winapi.SM_CYDOUBLECLK)
	return w, h
end

function app:time()
	return winapi.QueryPerformanceCounter().QuadPart
end

function app:timediff(start_time, end_time)
	self.qpf = self.qpf or tonumber(winapi.QueryPerformanceFrequency().QuadPart)
	end_time = end_time or winapi.QueryPerformanceCounter().QuadPart
	local interval = end_time - start_time
	return tonumber(interval * 1000) / self.qpf --milliseconds
end

--window impl

local window = {}
app.window_class = window

local Window = winapi.subclass({}, winapi.Window)

function window:_new_view() end --stub

function app:window(t)
	self = glue.inherit({app = self}, self.window_class)

	if t.state == 'fullscreen' then
		--TODO
	end

	self.win = Window{
		visible = false,
		title = t.title,
		state = t.state,

		titlebar = t.frame,
		dialog_frame = t.frame,

		sizeable = t.allow_resize,
		minimize_button = t.allow_minimize,
		maximize_button = t.allow_maximize,
		noclose = t.allow_close == false,
		--tool_window = t.frame == false,

		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		receive_double_clicks = false, --we do our own double-clicking
	}

	self.win.__wantallkeys = true --don't let the message loop call IsDialogMessage() and filter our WM_CHARs
	self.delegate = t.delegate
	self.win.delegate = t.delegate
	self.view = self:_new_view()

	--init mouse state
	local m = self.delegate.mouse
	local pos = winapi.GetCursorPos()
	m.x = pos.x
	m.y = pos.y
	m.left = winapi.GetKeyState(winapi.VK_LBUTTON)
	m.middle = winapi.GetKeyState(winapi.VK_MBUTTON)
	m.right = winapi.GetKeyState(winapi.VK_RBUTTON)
	m.xbutton1 = winapi.GetKeyState(winapi.VK_XBUTTON1)
	m.xbutton2 = winapi.GetKeyState(winapi.VK_XBUTTON2)

	--start tracking mouse leave
	winapi.TrackMouseEvent{hwnd = self.win.hwnd, flags = winapi.TME_LEAVE}

	return self
end

function window:free()
	self.win:close()
end

function window:dead()
	return self.win.dead
end

function Window:on_close()
	if self.delegate:event'closing' == false then
		return 0
	end
end

function Window:on_destroy()
	self.delegate:event'closed'
end

--activation

function window:activate()
	self.win:activate()
end

function window:active()
	return self.win.active
end

function Window:on_activate()
	self.delegate:event'activated'
end

function Window:on_deactivate()
	self.delegate:event'deactivated'
end

--state

function window:show(state)
	local curstate = self:state()
	local visible = self:visible()
	state = state or curstate
	if curstate == state and visible then return end

	if state == 'fullscreen' then
		self._fullscreen = true
		self._fullscreen_state = {
			titlebar = self.win.titlebar,
			dialog_frame = self.win.dialog_frame,
			state = self.win.state,
			frame_rect = self.win.state == 'normal' and self.win.rect or nil,
		}
		self.win.titlebar = false
		self.win.dialog_frame = false
		if self.win.state == 'minimized' then
			self.win:show'normal'
		end
		self.win:move(self.app:screen_rect())
		self:activate()
	else
		if self._fullscreen then
			local t = self._fullscreen_state
			self.win.titlebar = t.titlebar
			self.win.dialog_frame = t.dialog_frame
			state = state or t.state
			if state == 'normal' then
				self.win.rect = t.frame_rect
			else
				self._normal_rect = t.frame_rect
				self.win:show(state)
			end
			self._fullscreen = false
		else
			if state == 'normal' and self._normal_rect then
				self.win.rect = self._normal_rect
				self._normal_rect = nil
			end
			self.win:show(state)
		end
	end
	if self:active() then
		self.delegate:event'activated'
	end
end

function window:hide()
	self.win:hide()
end

function window:visible()
	return self.win.visible
end

function window:state()
	return self._fullscreen and 'fullscreen' or self.win.state
end

--positioning

function window:frame_rect(x, y, w, h)
	self.win:move(x, y, w, h)
	return unpack_rect(self.win.rect)
end

function window:client_rect()
	return unpack_rect(self.win.client_rect)
end

function Window:frame_changing(how, rect)
	local x, y, w, h = self.delegate:event('frame_changing', how, unpack_rect(rect))
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
	self.delegate:event'moved'
end

function Window:on_resized(flag)
	print('>', flag)
	self.delegate:event'resized'
end

function Window:on_pos_changed()
	print('>>', 'pos_changed')
end

--frame

function window:title(newtitle)
	if newtitle then
		self.win.title = newtitle
	else
		return self.win.title
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
		self.delegate:event('key_down', key)
	end
	self.delegate:event('key_press', key)
end

function Window:on_key_up(vk)
	self.delegate:event('key_up', keyname(vk))
end

--we get the ALT key with this messages instead
Window.on_syskey_down = Window.on_key_down
Window.on_syskey_up = Window.on_key_up

function Window:on_key_down_char(char)
	self.delegate:event('key_char', char)
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

	--send mouse_enter
	if not self._mouse_entered then
		self._mouse_entered = true
		winapi.TrackMouseEvent{hwnd = self.hwnd, flags = winapi.TME_LEAVE}
		self.delegate:event'mouse_enter'
	end
end

function Window:on_mouse_move(x, y, buttons)
	local m = self.delegate.mouse
	local moved = x ~= m.x or y ~= m.y
	self:setmouse(x, y, buttons)
	if moved then
		self.delegate:event('mouse_move', x, y)
	end
end

function Window:on_mouse_leave()
	if not self._mouse_entered then return end
	self._mouse_entered = false
	self.delegate:event'mouse_leave'
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
	self.delegate:event('mouse_down', 'left')
end

function Window:on_mbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:capture_mouse()
	self.delegate:event('mouse_down', 'middle')
end

function Window:on_rbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:capture_mouse()
	self.delegate:event('mouse_down', 'right')
end

function Window:on_xbutton_down(x, y, buttons)
	self:setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:capture_mouse()
		self.delegate:event('mouse_down', 'xbutton1')
	end
	if buttons.xbutton2 then
		self:capture_mouse()
		self.delegate:event('mouse_down', 'xbutton2')
	end
end

function Window:on_lbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:event('mouse_up', 'left')
end

function Window:on_mbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:event('mouse_up', 'middle')
end

function Window:on_rbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	self:uncapture_mouse()
	self.delegate:event('mouse_up', 'right')
end

function Window:on_xbutton_up(x, y, buttons)
	self:setmouse(x, y, buttons)
	if buttons.xbutton1 then
		self:uncapture_mouse()
		self.delegate:event('mouse_up', 'xbutton1')
	end
	if buttons.xbutton2 then
		self:uncapture_mouse()
		self.delegate:event('mouse_up', 'xbutton2')
	end
end

function Window:on_mouse_wheel(x, y, buttons, delta)
	delta = math.floor(delta / 120) --note: when scrolling backwards I get -119 instead of -120
	self:setmouse(x, y, buttons)
	self.delegate:event('mouse_wheel', delta)
end

function Window:on_mouse_hwheel(x, y, buttons, delta)
	delta = delta / 120
	self:setmouse(x, y, buttons)
	self.delegate:event('mouse_hwheel', delta)
end

--rendering

function window:invalidate()
	self.win:invalidate()
end

function Window:on_paint()
	self.delegate:event'render'
end


if not ... then require'nw_demo' end

--return an api subclass with this implementation
return glue.inherit({impl = nw}, require'nw_api')

