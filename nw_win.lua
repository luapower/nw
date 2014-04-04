--native widgets winapi implementation
local winapi = require'winapi'
require'winapi.windowclass'
require'winapi.messageloop'
require'winapi.spi'
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

--window impl

local window = {}
app.window_class = window

local Window = winapi.subclass({}, winapi.Window)

function window:_new_view() end --stub

function app:window(t)
	self = glue.inherit({}, self.window_class)
	self.win = Window{
		visible = false,
		title = t.title,
		state = t.state,
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
	}
	self.win.__wantallkeys = true --don't let the message loop call IsDialogMessage() and filter our WM_CHARs
	self.delegate = t.delegate
	self.win.delegate = t.delegate
	self.win.impl = self
	self.view = self:_new_view()
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
	if state == 'fullscreen' then
		--TODO
	else
		self.win:show(state)
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
	--TODO: fullscreen
	return self.win.state
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
	print('>')
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
	[0x08] = 'backspace',[0x09] = 'tab',      [0x0d] = 'return',   [0x10] = 'shift',    [0x11] = 'ctrl',
	[0x12] = 'alt',      [0x13] = 'break',    [0x14] = 'caps',     [0x1b] = 'esc',      [0x20] = 'space',
	[0x21] = 'pageup',   [0x22] = 'pagedown', [0x23] = 'end',      [0x24] = 'home',     [0x25] = 'left',
	[0x26] = 'up',       [0x27] = 'right',    [0x28] = 'down',     [0x2c] = 'printscreen',
	[0x2d] = 'insert',   [0x2e] = 'delete',   [0x60] = 'numpad0',  [0x61] = 'numpad1',  [0x62] = 'numpad2',
	[0x63] = 'numpad3',  [0x64] = 'numpad4',  [0x65] = 'numpad5',  [0x66] = 'numpad6',  [0x67] = 'numpad7',
	[0x68] = 'numpad8',  [0x69] = 'numpad9',  [0x6a] = 'multiply', [0x6b] = 'add',      [0x6c] = 'separator',
	[0x6d] = 'subtract', [0x6e] = 'decimal',  [0x6f] = 'divide',   [0x70] = 'f1',       [0x71] = 'f2',
	[0x72] = 'f3',       [0x73] = 'f4',       [0x74] = 'f5',       [0x75] = 'f6',       [0x76] = 'f7',
	[0x77] = 'f8',       [0x78] = 'f9',       [0x79] = 'f10',      [0x7a] = 'f11',      [0x7b] = 'f12',
	[0x90] = 'numlock',  [0x91] = 'scrolllock',
	--varying by keyboard
	[0xba] = ';',        [0xbb] = '+',        [0xbc] = ',',        [0xbd] = '-',        [0xbe] = '.',
	[0xbf] = '/',        [0xc0] = '`',        [0xdb] = '[',        [0xdc] = '\\',       [0xdd] = ']',
	[0xde] = "'",
}

local function keyname(vk)
	return
		(((vk >= string.byte'0' and vk <= string.byte'9') or
		(vk >= string.byte'A' and vk <= string.byte'Z'))
			and string.char(vk) or keynames[vk])
end

local keycodes = glue.index(keynames)

local function keycode(name)
	return keycodes[name] or string.byte(name)
end

local function key_event(window, vk, flags, down)
	panel:invalidate()
end

function Window:on_key_down(vk, flags)
	if not flags.prev_key_state then
		self.delegate:event('key_down', keyname(vk))
	end
	self.delegate:event('key_press', keyname(vk))
end

function Window:on_key_up(vk)
	self.delegate:event('key_up', keyname(vk))
end

--mouse

function Window:on_mouse_move()
	self.delegate:event'mouse_move'
end

function Window:on_mouse_over()
	self.delegate:event'mouse_over'
end

function Window:on_mouse_leave()
	self.delegate:event'mouse_leave'
end

--[[
		on_lbutton_double_click = WM_LBUTTONDBLCLK,
		on_lbutton_down = WM_LBUTTONDOWN,
		on_lbutton_up = WM_LBUTTONUP,
		on_mbutton_double_click = WM_MBUTTONDBLCLK,
		on_mbutton_down = WM_MBUTTONDOWN,
		on_mbutton_up = WM_MBUTTONUP,
		on_rbutton_double_click = WM_RBUTTONDBLCLK,
		on_rbutton_down = WM_RBUTTONDOWN,
		on_rbutton_up = WM_RBUTTONUP,
		on_xbutton_double_click = WM_XBUTTONDBLCLK,
		on_xbutton_down = WM_XBUTTONDOWN,
		on_xbutton_up = WM_XBUTTONUP,
		on_mouse_wheel = WM_MOUSEWHEEL,
		on_mouse_hwheel = WM_MOUSEHWHEEL,
]]

--[[
function window:mouse_move(x, y) end
function window:mouse_over() end
function window:mouse_leave() end
function window:mouse_up(button) end
function window:mouse_down(button) end
function window:click(button) end
function window:double_click(button) end
function window:triple_click(button) end
function window:mouse_wheel(delta) end
]]

--rendering

function window:invalidate()
	self.win:invalidate()
end


if not ... then require'nw_demo' end

--return an api subclass with this implementation
return glue.inherit({impl = nw}, require'nw_api')
