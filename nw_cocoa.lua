--native widgets cococa backend (Cosmin Apreutesei, public domain).

--cocoa lessons:
--windows are created hidden by default.
--zoom()'ing a hidden window does not show it (but does change its maximized flag).
--orderOut() doesn't hide window if it's the key window (instead it disables mouse on it making it appear frozen).
--makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--isVisible() returns false both when the window is orderOut() and when it's minimized().
--activateIgnoringOtherApps(false) puts windows created after behind the active app.
--activateIgnoringOtherApps(true) puts windows created after in front of the active app.
--only the windows made key after the call to activateIgnoringOtherApps(true) are put in front of the active app!
--quitting the app from the app's Dock menu (or calling terminate(nil)) calls appShouldTerminate, then calls close()
--on all windows, thus without calling windowShouldClose, but only windowWillClose.
--there's no windowDidClose event and so windowDidResignKey comes after windowWillClose.
--screen:visibleFrame() is in virtual screen coordinates just like winapi's MONITORINFO.
--applicationWillTerminate() is never called.
--terminate() doesn't return, unless applicationShouldTerminate returns false
--creating and closing a window and not starting the app loop at all segfaults on exit (is this TLC or cocoa?).

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local objc = require'objc'

objc.load'Foundation'
objc.load'AppKit'
objc.load'System'
objc.load'CoreServices'
objc.load'/System/Library/Frameworks/Carbon.framework/Versions/Current/Frameworks/HIToolbox.framework' --for key codes

io.stdout:setvbuf'no'

local function unpack_rect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local backend = {}

function backend:app(api)
	return self.app_class:new(api)
end

--app class

local app = {}
backend.app_class = app

--app init

local NSApp = objc.class('NSApp', 'NSApplication <NSApplicationDelegate>')

function NSApp:applicationShouldTerminate()
	self.api:_backend_quitting() --calls quit() which calls stop()
	return false
end

function NSApp:applicationDidChangeScreenParameters()
	self.api:_backend_displays_changed()
end

function app:new(api)

	self = glue.inherit({api = api}, self)

	self.pool = objc.NSAutoreleasePool:new()

	self.app = NSApp:sharedApplication()
	self.app.api = api
	self.app.app = self

	self.app:setDelegate(self.app)
	--set it to be a normal app with dock and menu bar
	self.app:setActivationPolicy(objc.NSApplicationActivationPolicyRegular)
	self.app:setPresentationOptions(self.app:presentationOptions() + objc.NSApplicationPresentationFullScreen)

	objc.NSEvent:setMouseCoalescingEnabled(false)

	return self
end

--run/quit

function app:run()
	self.app:run()
end

function app:stop()
	self.app:stop(nil)
	--post a dummy event to ensure the stopping
	local event = objc.NSEvent:
		otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
			objc.NSApplicationDefined, objc.NSMakePoint(0,0), 0, 0, 0, nil, 1, 1, 1)
	self.app:postEvent_atStart(event, true)
end

--timers

objc.addmethod('NSApp', 'timerEvent', function(self, timer)
	local func = self.app.timers[objc.nptr(timer)]
	self.app.timers[objc.nptr(timer)] = nil
	func()
end, 'v@:@')

function app:runafter(seconds, func)
	local timer = objc.NSTimer:scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
		seconds, self.app, 'timerEvent', nil, false)
	self.timers = self.timers or {}
	self.timers[objc.nptr(timer)] = func --the timer is retained by the scheduler so we don't have to ref it
end

--app activation

function app:activate()
	self.app:activateIgnoringOtherApps(true)
end

--displays

--convert rect from bottom-up relative-to-main-screen space to top-down relative-to-main-screen space
local function flip_rect(main_h, x, y, w, h)
	return x,  main_h - h - y, w, h
end

local function display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_rect(main_h, unpack_rect(screen:frame()))
	t.client_x, t.client_y, t.client_w, t.client_h = flip_rect(main_h, unpack_rect(screen:visibleFrame()))
	return t
end

function app:displays()
	objc.NSScreen:mainScreen() --calling this before calling screens() prevents a weird NSRecursiveLock error
	local screens = objc.NSScreen:screens()

	--get main_h from the screens snapshot array
	local frame = screens:objectAtIndex(0):frame() --main screen always comes first
	assert(frame.origin.x == 0 and frame.origin.y == 0) --main screen alright
	local main_h = frame.size.height

	--build the list of display objects to return
	local displays = {}
	for i = 0, tonumber(screens:count()-1) do
		table.insert(displays, display(main_h, screens:objectAtIndex(i)))
	end
	return displays
end

function app:main_display()
	local screen = objc.NSScreen:mainScreen()
	return display(screen:frame().size.height, screen)
end

--double-clicking info

function app:double_click_time() --milliseconds
	return objc.NSEvent:doubleClickInterval() * 1000
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

--time

function app:time()
	return objc.mach_absolute_time()
end

function app:timediff(start_time, end_time)
	if not self.timebase then
		self.timebase = ffi.new'mach_timebase_info_data_t'
		objc.mach_timebase_info(self.timebase)
	end
	return tonumber(end_time - start_time) * self.timebase.numer / self.timebase.denom / 10^6
end

function app:window(api, t)
	return self.window_class:new(self, api, t)
end

--window class

local window = {}
app.window_class = window

--window creation

local NWWindow = objc.class('NWWindow', 'NSWindow <NSWindowDelegate>')

function NWWindow:windowShouldClose()
	return self.api:_backend_closing() or false
end

function NWWindow:windowWillClose()
	--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
	if self.win:active() then
		self._close_on_deactivate = true
	else
		self.api:_backend_closed()
	end
end

function NWWindow:windowDidBecomeKey()
	self.api:_backend_activated()
end

function NWWindow:windowDidResignKey()
	self.api:_backend_deactivated()

	--check for defered close
	if self._close_on_deactivate then
		self.api:_backend_closed()
	end
end

--fullscreen mode

function NWWindow:windowWillEnterFullScreen()
	print'enter fullscreen'
	--self:toggleFullScreen(nil)
	self:setStyleMask(self:styleMask() + objc.NSFullScreenWindowMask)
	--self:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
end

function NWWindow:windowWillExitFullScreen()
	print'exit fullscreen'
end

function NWWindow:willUseFullScreenPresentationOptions(options)
	print('here1', options)
	return options
end

--TODO: hack
objc.override(NWWindow, 'willUseFullScreenContentSize', function(size)
	print('here2', size)
end, 'd@:@dd')

function NWWindow:customWindowsToEnterFullScreenForWindow()
	return {self}
end

function NWWindow:customWindowsToExitFullScreenForWindow()
	return {self}
end

function window:new(app, api, t)
	self = glue.inherit({app = app, api = api}, self)

	local style = t.frame == 'normal' and bit.bor(
							objc.NSTitledWindowMask,
							t.closeable and objc.NSClosableWindowMask or 0,
							t.minimizable and objc.NSMiniaturizableWindowMask or 0,
							t.resizeable and objc.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(objc.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(objc.NSBorderlessWindowMask) --TODO

	local main_h = objc.NSScreen:mainScreen():frame().size.height
	local frame_rect = objc.NSMakeRect(flip_rect(main_h, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = NWWindow:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)
	self.nswin:setReleasedWhenClosed(false)

	if t.fullscreenable then
		self.nswin:setCollectionBehavior(objc.NSWindowCollectionBehaviorFullScreenPrimary)
	end

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end

	--self.nswin:setAcceptsMouseMovedEvents(true)

	local opts = bit.bor(
		objc.NSTrackingActiveAlways,
		objc.NSTrackingInVisibleRect,
		objc.NSTrackingMouseEnteredAndExited,
		objc.NSTrackingMouseMoved)

	local area = objc.NSTrackingArea:alloc():initWithRect_options_owner_userInfo(
		self.nswin:contentView():bounds(), opts, self.nswin:contentView(), nil)
	self.nswin:contentView():addTrackingArea(area)

	if not t.maximizable then

		--emulate windows behavior of hiding the minimize and maximize buttons when they're both disabled
		if not t.minimizable then
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setHidden(true)
			self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
		else
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setEnabled(false)
		end
	end

	self.nswin:setTitle(t.title)

	if t.maximized then
		if not self:maximized() then
			self.nswin:zoom(nil) --doesn't show the window if it's not already visible
		end
	end

	--enable events
	self.nswin.api = api
	self.nswin.win = self
	self.nswin:setDelegate(self.nswin)

	self._show_minimized = t.minimized --minimize on the next show()
	self._show_fullscreen = t.fullscreen --fullscreen on the next show()
	self._visible = false

	return self
end

--closing

function window:close()
	self.nswin:close() --doesn't call windowShouldClose
end

--activation

function window:activate()
	if not self._visible then
		self.app:activate() --activate the app but leave the window hidden like in windows
	else
		self.nswin:makeKeyAndOrderFront(nil)
	end
end

function window:active()
	return self.nswin:isKeyWindow()
end

--visibility

function window:show()
	self._visible = true
	self.app:activate()
	if self._show_minimized then
		self._show_minimized = nil
		if self._show_fullscreen then
			self:_enter_fullscreen(true)
		else
			self.nswin:miniaturize(nil)
		end
	else
		if self._show_fullscreen then
			self:_enter_fullscreen()
		else
			self.nswin:makeKeyAndOrderFront(nil)
		end
	end
end

function window:hide()
	self._visible = false
	self.nswin:orderOut(nil)
end

function window:visible()
	return self._visible
end

--state

function window:minimize()
	self._visible = true
	self.nswin:miniaturize(nil)
end

function window:maximize()
	if not self:maximized() then
		self.nswin:zoom(nil)
	end
	self:show()
end

function window:restore()
	if self:maximized() then
		self.nswin:zoom(nil)
	elseif self:minimized() then
		self.nswin:deminiaturize()
	end
end

function window:shownormal()
	if self:maximized() then
		self:restore()
	end
	if not self:visible() then
		self:show()
	end
end

function window:minimized()
	return self.nswin:isMiniaturized()
end

function window:maximized()
	return self.nswin:isZoomed()
end

function window:_enter_fullscreen(show_minimized)
	self._show_fullscreen = nil
	self.nswin:toggleFullScreen(nil)
	--self.nswin:setStyleMask(self.nswin:styleMask() + objc.NSFullScreenWindowMask)
	--self.nswin:contentView():enterFullScreenMode_withOptions(objc.NSScreen:mainScreen(), nil)
end

function window:_exit_fullscreen(show_maximized)
	self.nswin:toggleFullScreen(nil)
	--
end

function window:fullscreen(fullscreen)
	if fullscreen ~= nil then
		if fullscreen ~= self:fullscreen() then
			if fullscreen then
				self:_enter_fullscreen()
			else
				self:_exit_fullscreen()
			end
		end
	else
		return self._show_fullscreen or
			bit.band(tonumber(self.nswin:styleMask()), objc.NSFullScreenWindowMask) == objc.NSFullScreenWindowMask
	end
end

--frame

function window:display()
	return self.nswin:screen()
end

function window:title(title)
	if title then
		self.nswin:setTitle(NSStr(title))
	else
		return self.nswin:title()
	end
end

--keyboard

local keycodes = {

	['0'] = objc.kVK_ANSI_0,
	['1'] = objc.kVK_ANSI_1,
	['2'] = objc.kVK_ANSI_2,
	['3'] = objc.kVK_ANSI_3,
	['4'] = objc.kVK_ANSI_4,
	['5'] = objc.kVK_ANSI_5,
	['6'] = objc.kVK_ANSI_6,
	['7'] = objc.kVK_ANSI_7,
	['8'] = objc.kVK_ANSI_8,
	['9'] = objc.kVK_ANSI_9,

	A = objc.kVK_ANSI_A,
	B = objc.kVK_ANSI_B,
	C = objc.kVK_ANSI_C,
	D = objc.kVK_ANSI_D,
	E = objc.kVK_ANSI_E,
	F = objc.kVK_ANSI_F,
	G = objc.kVK_ANSI_G,
	H = objc.kVK_ANSI_H,
	I = objc.kVK_ANSI_I,
	J = objc.kVK_ANSI_J,
	K = objc.kVK_ANSI_K,
	L = objc.kVK_ANSI_L,
	M = objc.kVK_ANSI_M,
	N = objc.kVK_ANSI_N,
	O = objc.kVK_ANSI_O,
	P = objc.kVK_ANSI_P,
	Q = objc.kVK_ANSI_Q,
	R = objc.kVK_ANSI_R,
	S = objc.kVK_ANSI_S,
	T = objc.kVK_ANSI_T,
	U = objc.kVK_ANSI_U,
	V = objc.kVK_ANSI_V,
	W = objc.kVK_ANSI_W,
	X = objc.kVK_ANSI_X,
	Y = objc.kVK_ANSI_Y,
	Z = objc.kVK_ANSI_Z,

	[';'] = objc.kVK_ANSI_Semicolon,
	['+'] = objc.kVK_ANSI_Equal,
	[','] = objc.kVK_ANSI_Comma,
	['-'] = objc.kVK_ANSI_Minus,
	['.'] = objc.kVK_ANSI_Period,
	['/'] = objc.kVK_ANSI_Slash,
	['`'] = objc.kVK_ANSI_Grave,
	['['] = objc.kVK_ANSI_LeftBracket,
	['\\'] = objc.kVK_ANSI_Backslash,
	[']'] = objc.kVK_ANSI_RightBracket,
	["'"] = objc.kVK_ANSI_Quote,

	backspace   = objc.kVK_Delete,
	tab         = objc.kVK_Tab,
	enter       = objc.kVK_Return,
	space       = objc.kVK_Space,
	esc         = objc.kVK_Escape,

	F1 = objc.kVK_F1,
	F2 = objc.kVK_F2,
	F3 = objc.kVK_F3,
	F4 = objc.kVK_F4,
	F5 = objc.kVK_F5,
	F6 = objc.kVK_F6,
	F7 = objc.kVK_F7,
	F8 = objc.kVK_F8,
	F9 = objc.kVK_F9,
	F10 = objc.kVK_F10,
	F11 = objc.kVK_F11, --captured: show desktop
	F12 = objc.kVK_F12, --captured: show the wachamacalit wall with the calendar and clock

	shift  = objc.kVK_Shift,
	ctrl   = objc.kVK_Control,
	alt    = objc.kVK_Option,
	lshift = objc.kVK_Shift,
	rshift = objc.kVK_RightShift,
	lctrl  = objc.kVK_Control,
	rctrl  = objc.kVK_RightControl,
	lalt   = objc.kVK_Option,
	ralt   = objc.kVK_RightOption,

	capslock    = objc.kVK_CapsLock,
	numlock     = 71,  --but no light (also this is kVK_ANSI_KeypadClear wtf)
	scrolllock  = nil, --captured: brightness down
	['break']   = nil, --captured: brightness up
	printscreen = objc.kVK_F13,

	left        = objc.kVK_LeftArrow,
	up          = objc.kVK_UpArrow,
	right       = objc.kVK_RightArrow,
	down        = objc.kVK_DownArrow,

	pageup      = objc.kVK_PageUp,
	pagedown    = objc.kVK_PageDown,
	home        = objc.kVK_Home,
	['end']     = objc.kVK_End,
	insert      = objc.kVK_Help,
	delete      = objc.kVK_ForwardDelete,

	--numpad (numlock doesn't work)
	numpad0 = objc.kVK_ANSI_Keypad0,
	numpad1 = objc.kVK_ANSI_Keypad1,
	numpad2 = objc.kVK_ANSI_Keypad2,
	numpad3 = objc.kVK_ANSI_Keypad3,
	numpad4 = objc.kVK_ANSI_Keypad4,
	numpad5 = objc.kVK_ANSI_Keypad5,
	numpad6 = objc.kVK_ANSI_Keypad6,
	numpad7 = objc.kVK_ANSI_Keypad7,
	numpad8 = objc.kVK_ANSI_Keypad8,
	numpad9 = objc.kVK_ANSI_Keypad9,
	['numpad.'] = objc.kVK_ANSI_KeypadDecimal,

	--numpad (single function)
	['numpad*'] = objc.kVK_ANSI_KeypadMultiply,
	['numpad+'] = objc.kVK_ANSI_KeypadPlus,
	['numpad-'] = objc.kVK_ANSI_KeypadMinus,
	['numpad/'] = objc.kVK_ANSI_KeypadDivide,
	numpadenter = objc.kVK_ANSI_KeypadEnter,

	--multimedia
	mute       = objc.kVK_Mute,
	volumedown = objc.kVK_VolumeDown,
	volumeup   = objc.kVK_VolumeUp,

	--mac keyboard
	command = objc.kVK_Command,

	--windows keyboard
	menu = 110,
}

local keynames = glue.index(keycodes)

local function keyname(event)
	local keycode = event:keyCode()
	return keynames[keycode] or tostring(keycode)
end

function NWWindow:keyDown(event)
	local key = keyname(event)
	if not key then return end
	self.api:_backend_keypress(key)
end

function NWWindow:keyUp(event)
	local key = keyname(event)
	if not key then return end
	self.api:_backend_keyup(key)
end

--mouse

function NWWindow:setmouse(event)
	local m = self.api.mouse
	local pos = event:mouseLocation()
	m.x = pos.x
	m.y = pos.y
	local btns = tonumber(event:pressedMouseButtons())
	m.left = bit.band(btns, 1) ~= 0
	m.right = bit.band(btns, 2) ~= 0
	m.middle = bit.band(btns, 4) ~= 0
	m.xbutton1 = bit.band(btns, 8) ~= 0
	m.xbutton2 = bit.band(btns, 16) ~= 0
	return m
end

function NWWindow:mouseDown(event)
	self:setmouse(event)
	self.api:_backend_mousedown'left'
end

function NWWindow:mouseUp(event)
	self:setmouse(event)
	self.api:_backend_mouseup'left'
end

function NWWindow:rightMouseDown(event)
	self:setmouse(event)
	self.api:_backend_mousedown'right'
end

function NWWindow:rightMouseUp(event)
	self:setmouse(event)
	self.api:_backend_mouseup'right'
end

local other_buttons = {'', 'middle', 'xbutton1', 'xbutton2'}

function NWWindow:otherMouseDown(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	self:setmouse(event)
	self.api:_backend_mousedown(btn)
end

function NWWindow:otherMouseUp(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	self:setmouse(event)
	self.api:_backend_mouseup(btn)
end

function NWWindow:mouseMoved(event)
	local m = self:setmouse(event)
	self.api:_backend_mousemove(m.x, m.y)
end

function NWWindow:mouseDragged(event)
	self:mouseMoved(event)
end

function NWWindow:rightMouseDragged(event)
	self:mouseMoved(event)
end

function NWWindow:otherMouseDragged(event)
	self:mouseMoved(event)
end

function NWWindow:mouseEntered(event)
	self:setmouse(event)
	self.api:_backend_mouseenter()
end

function NWWindow:mouseExited(event)
	self:setmouse(event)
	self.api:_backend_mouseleave()
end

function NWWindow:scrollWheel(event)
	self:setmouse(event)
	local dx = event:deltaX()
	if dx ~= 0 then
		self.api:_backend_mousehwheel(dx)
	end
	local dy = event:deltaY()
	if dy ~= 0 then
		self.api:_backend_mousewheel(dy)
	end
end

if not ... then require'nw_test' end

return backend
