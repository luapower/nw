--native widgets cococa backend (Cosmin Apreutesei, public domain)

--cocoa notes, or why cocoa sucks oh so, so much:

--zoom()'ing a hidden window does not show it (but does change its maximized flag).
--orderOut() doesn't hide a window if it's the key window (instead it disables mouse on it making it appear frozen).
--makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--isVisible() returns false both when the window is orderOut() and when it's minimized().
--windows created after calling activateIgnoringOtherApps(false) go behind the active app.
--windows created after calling activateIgnoringOtherApps(true) go in front of the active app.
--only the windows made key after the call to activateIgnoringOtherApps(true) are put in front of the active app!
--quitting the app from the app's Dock menu (or calling terminate(nil)) calls appShouldTerminate, then calls close()
--  on all windows, thus without calling windowShouldClose, but only windowWillClose.
--there's no windowDidClose event and so windowDidResignKey comes after windowWillClose.
--screen:visibleFrame() is in virtual screen coordinates just like winapi's MONITORINFO.
--applicationWillTerminate() is never called.
--terminate() doesn't return, unless applicationShouldTerminate() returns false.
--no keyDown() for modifier keys, must use flagsChanged().
--flagsChanged() returns undocumented, and possibly not portable bits to distinguish between left/right modifier keys.
--these bits are not given with NSEvent:modifierFlags(), so we can't get the initial state of specific modifier keys.
--no keyDown() on the 'help' key (which is the 'insert' key on a win keyboard).
--flagsChanged() can only get you so far in simulating keyDown/keyUp events for the modifier keys:
--  holding down these keys won't trigger repeated key events.
--  can't know when capslock is depressed, only when it is pressed.
--no event while moving a window - frame() is not updated while moving the window either.
--can't know which corner/side a window is dragged by to be resized. good luck implementing edge snapping correctly.
--can't reference resizing cursors directly with constants, must dig and get them yourself.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local objc = require'objc'
local box2d = require'box2d'

objc.load'Foundation'
objc.load'AppKit'
objc.load'System' --for mach_absolute_time
objc.load'Carbon.HIToolbox' --for key codes

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
local function flip_screen_rect(main_h, x, y, w, h)
	main_h = main_h or objc.NSScreen:mainScreen():frame().size.height
	return x, main_h - h - y, w, h
end

local function display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_screen_rect(main_h, unpack_rect(screen:frame()))
	t.client_x, t.client_y, t.client_w, t.client_h = flip_screen_rect(main_h, unpack_rect(screen:visibleFrame()))
	return t
end

function app:displays()
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
	return display(nil, screen)
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

local NWView = objc.class('NSView')

function window:new(app, api, t)
	self = glue.inherit({app = app, api = api}, self)

	local style = t.frame == 'normal' and bit.bor(
							objc.NSTitledWindowMask,
							t.closeable and objc.NSClosableWindowMask or 0,
							t.minimizable and objc.NSMiniaturizableWindowMask or 0,
							t.resizeable and objc.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(objc.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(objc.NSBorderlessWindowMask) --TODO

	local frame_rect = objc.NSMakeRect(flip_screen_rect(nil, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = NWWindow:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)
	ffi.gc(self.nswin, nil) --disown

	local view = NWView:alloc():initWithFrame(objc.NSMakeRect(0, 0, 100, 100))
	self.nswin:setContentView(view)
	ffi.gc(view, nil) --disown, nswin owns it now

	self.nswin:setMovable(false)

	self.nswin:reset_keystate()

	if t.fullscreenable then
		self.nswin:setCollectionBehavior(objc.NSWindowCollectionBehaviorFullScreenPrimary)
	end

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end

	local opts = bit.bor(
		objc.NSTrackingActiveInKeyWindow,
		objc.NSTrackingInVisibleRect,
		objc.NSTrackingMouseEnteredAndExited,
		objc.NSTrackingMouseMoved,
		objc.NSTrackingCursorUpdate)

	--self.nswin:setAcceptsMouseMovedEvents(true)

	local r = self.nswin:contentView():bounds()
	local area = objc.NSTrackingArea:alloc():initWithRect_options_owner_userInfo(
		r, opts, self.nswin:contentView(), nil)
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

function NWWindow:windowShouldClose()
	return self.api:_backend_closing() or false
end

function NWWindow:windowWillClose()
	--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
	if self.win:active() then
		self._close_on_deactivate = true
	else
		self.api:_backend_closed()
		self.nswin = nil
	end
end

function NWWindow:windowDidBecomeKey()
	self.dragging = false
	self:reset_keystate()
	self.api:_backend_activated()
end

function NWWindow:windowDidResignKey()
	self.dragging = false
	self:reset_keystate()
	self.api:_backend_deactivated()

	--check for defered close
	if self._close_on_deactivate then
		self.api:_backend_closed()
		self.nswin = nil
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

function NWWindow:canBecomeKeyWindow() --windows with NSBorderlessWindowMask can't become key by default
	return true
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

--positioning

function NWWindow:flip_y(x, y) --flip a contentView-relative y coordinate
	return x, self:contentView():frame().size.height - y
end

function NWWindow:clientarea_hit(event)
	local mp = event:locationInWindow()
	local rc = self:contentView():bounds()
	return box2d.hit(mp.x, mp.y, unpack_rect(rc))
end

local buttons = {
	objc.NSWindowCloseButton,
	objc.NSWindowMiniaturizeButton,
	objc.NSWindowZoomButton,
	objc.NSWindowToolbarButton,
	objc.NSWindowDocumentIconButton,
	objc.NSWindowDocumentVersionsButton,
	objc.NSWindowFullScreenButton,
}
function NWWindow:titlebar_buttons_hit(event)
	for i,btn in ipairs(buttons) do
		local button = self:standardWindowButton(btn)
		if button then
			if button:hitTest(button:superview():convertPoint_fromView(event:locationInWindow(), nil)) then
				return true
			end
		end
	end
end

local function resize_area_hit(mx, my, w, h)
	local co = 15 --corner offset
	local mo = 4 --margin offset
	if box2d.hit(mx, my, box2d.offset(co, 0, 0, 0, 0)) then
		return 'bottomleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, 0, 0, 0)) then
		return 'bottomright'
	elseif box2d.hit(mx, my, box2d.offset(co, 0, h, 0, 0)) then
		return 'topleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, h, 0, 0)) then
		return 'topright'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, w, 0)) then
		return 'bottom'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, h, w, 0)) then
		return 'top'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, 0, h)) then
		return 'left'
	elseif box2d.hit(mx, my, box2d.offset(mo, w, 0, 0, h)) then
		return 'right'
	end
end

function NWWindow:resize_area_hit(event)
	local mp = event:locationInWindow()
	local _, _, w, h = unpack_rect(self:frame())
	return resize_area_hit(mp.x, mp.y, w, h)
end

function NWWindow:sendEvent(event)
	--take over window dragging by the titlebar so that we can post moving events
	local etype = event:type()
	if self.dragging then
		if etype == objc.NSLeftMouseDragged then
			local mp = event:mouseLocation()
			mp.x = mp.x - self.dragoffset.x
			mp.y = mp.y - self.dragoffset.y
			local frame = self:frame()
			local x, y, w, h = self.api:_backend_resizing('move', mp.x, mp.y, frame.size.width, frame.size.height)
			if x then
				self:setFrame_display(objc.NSMakeRect(x, y, w, h), false)
			else
				self:setFrameOrigin(mp)
			end
			return
		elseif etype == objc.NSLeftMouseUp then
			self.dragging = false
			self.mousepos = nil
			return
		end
	elseif etype == objc.NSLeftMouseDown
		and not self:clientarea_hit(event)
		and not self:titlebar_buttons_hit(event)
		and not self:resize_area_hit(event)
	then
		self.dragging = true
		local mp = event:mouseLocation()
		local wp = self:frame().origin
		mp.x = mp.x - wp.x
		mp.y = mp.y - wp.y
		self.dragoffset = mp
		self.dragging = true
		return
	elseif etype == objc.NSLeftMouseDown then
		self.mousepos = event:locationInWindow() --for resizing
	end
	objc.callsuper(self, 'sendEvent', event)
end

function NWWindow:windowWillStartLiveResize()
	local mx, my = self.mousepos.x, self.mousepos.y
	local _, _, w, h = unpack_rect(self:frame())
	self.how = resize_area_hit(mx, my, w, h)
end

function NWWindow:windowDidResize()
	local x, y, w, h = self.api:_backend_resizing(self.how, flip_screen_rect(nil, unpack_rect(self:frame())))
	if x then
		x, y, w, h = flip_screen_rect(nil, x, y, w, h)
		self:setFrame_display(objc.NSMakeRect(x, y, w, h), true)
	end
	self.api:_backend_resized()
end

--cursors

local cursors = {
	--pointers
	arrow = 'arrowCursor',
	ibeam = 'IBeamCursor',
	hand  = 'openHandCursor',
	cross = 'crosshairCursor',
	--app state
	busy  = 'busyButClickableCursor', --undocumented, whatever
}

local hi_cursors = {
	--pointers
	no    = 'notallowed',
	--move and resize
	nesw  = 'resizenortheastsouthwest',
	nwse  = 'resizenorthwestsoutheast',
	ew    = 'resizeeastwest',
	ns    = 'resizenorthsouth',
	move  = 'move',
}

local load_hicursor = objc.memoize(function(name)
	basepath = basepath or (objc.findframework'ApplicationServices.HIServices' .. '/Versions/Current/Resources/cursors')
	local curpath = string.format('%s/%s/cursor.pdf', basepath, name)
	local infopath = string.format('%s/%s/info.plist', basepath, name)
	local image = objc.NSImage:alloc():initByReferencingFile(curpath)
	local info = objc.NSDictionary:dictionaryWithContentsOfFile(infopath)
	local hotx = info:objectForKey('hotx'):doubleValue()
	local hoty = info:objectForKey('hoty'):doubleValue()
	return objc.NSCursor:alloc():initWithImage_hotSpot(image, objc.NSMakePoint(hotx, hoty))
end)

local function setcursor(name)
	if cursors[name] then
		objc.NSCursor[cursors[name]](objc.NSCursor):set()
	elseif hi_cursors[name] then
		load_hicursor(hi_cursors[name]):set()
	end
end

function window:cursor(name)
	if name ~= nil then
		if self._cursor == name then return end
		self._cursor = name
		self.nswin:invalidateCursorRectsForView(self.nswin:contentView()) --trigger cursorUpdate
	else
		return self._cursor
	end
end

function NWWindow:cursorUpdate(event)
	if self:clientarea_hit(event) then
		setcursor(self.win._cursor)
	else
		objc.callsuper(self, 'cursorUpdate', event)
	end
end

--frame

function window:display()
	return display(nil, self.nswin:screen())
end

function window:title(title)
	if title then
		self.nswin:setTitle(NSStr(title))
	else
		return self.nswin:title()
	end
end

--keyboard

local keynames = {

	[objc.kVK_ANSI_0] = '0',
	[objc.kVK_ANSI_1] = '1',
	[objc.kVK_ANSI_2] = '2',
	[objc.kVK_ANSI_3] = '3',
	[objc.kVK_ANSI_4] = '4',
	[objc.kVK_ANSI_5] = '5',
	[objc.kVK_ANSI_6] = '6',
	[objc.kVK_ANSI_7] = '7',
	[objc.kVK_ANSI_8] = '8',
	[objc.kVK_ANSI_9] = '9',

	[objc.kVK_ANSI_A] = 'A',
	[objc.kVK_ANSI_B] = 'B',
	[objc.kVK_ANSI_C] = 'C',
	[objc.kVK_ANSI_D] = 'D',
	[objc.kVK_ANSI_E] = 'E',
	[objc.kVK_ANSI_F] = 'F',
	[objc.kVK_ANSI_G] = 'G',
	[objc.kVK_ANSI_H] = 'H',
	[objc.kVK_ANSI_I] = 'I',
	[objc.kVK_ANSI_J] = 'J',
	[objc.kVK_ANSI_K] = 'K',
	[objc.kVK_ANSI_L] = 'L',
	[objc.kVK_ANSI_M] = 'M',
	[objc.kVK_ANSI_N] = 'N',
	[objc.kVK_ANSI_O] = 'O',
	[objc.kVK_ANSI_P] = 'P',
	[objc.kVK_ANSI_Q] = 'Q',
	[objc.kVK_ANSI_R] = 'R',
	[objc.kVK_ANSI_S] = 'S',
	[objc.kVK_ANSI_T] = 'T',
	[objc.kVK_ANSI_U] = 'U',
	[objc.kVK_ANSI_V] = 'V',
	[objc.kVK_ANSI_W] = 'W',
	[objc.kVK_ANSI_X] = 'X',
	[objc.kVK_ANSI_Y] = 'Y',
	[objc.kVK_ANSI_Z] = 'Z',

	[objc.kVK_ANSI_Semicolon]    = ';',
	[objc.kVK_ANSI_Equal]        = '=',
	[objc.kVK_ANSI_Comma]        = ',',
	[objc.kVK_ANSI_Minus]        = '-',
	[objc.kVK_ANSI_Period]       = '.',
	[objc.kVK_ANSI_Slash]        = '/',
	[objc.kVK_ANSI_Grave]        = '`',
	[objc.kVK_ANSI_LeftBracket]  = '[',
	[objc.kVK_ANSI_Backslash]    = '\\',
	[objc.kVK_ANSI_RightBracket] = ']',
	[objc.kVK_ANSI_Quote]        = '\'',

	[objc.kVK_Delete] = 'backspace',
	[objc.kVK_Tab]    = 'tab',
	[objc.kVK_Space]  = 'space',
	[objc.kVK_Escape] = 'esc',
	[objc.kVK_Return] = 'enter!',

	[objc.kVK_F1]  = 'F1',
	[objc.kVK_F2]  = 'F2',
	[objc.kVK_F3]  = 'F3',
	[objc.kVK_F4]  = 'F4',
	[objc.kVK_F5]  = 'F5',
	[objc.kVK_F6]  = 'F6',
	[objc.kVK_F7]  = 'F7',
	[objc.kVK_F8]  = 'F8',
	[objc.kVK_F9]  = 'F9',
	[objc.kVK_F10] = 'F10',
	[objc.kVK_F11] = 'F11', --taken on mac (show desktop)
	[objc.kVK_F12] = 'F12', --taken on mac (show dashboard)

	[objc.kVK_CapsLock] = 'capslock',

	[objc.kVK_LeftArrow]     = 'left!',
	[objc.kVK_UpArrow]       = 'up!',
	[objc.kVK_RightArrow]    = 'right!',
	[objc.kVK_DownArrow]     = 'down!',

	[objc.kVK_PageUp]        = 'pageup!',
	[objc.kVK_PageDown]      = 'pagedown!',
	[objc.kVK_Home]          = 'home!',
	[objc.kVK_End]           = 'end!',
	[objc.kVK_Help]          = 'help', --mac keyboard; 'insert!' key on win keyboard; no keydown, only keyup
	[objc.kVK_ForwardDelete] = 'delete!',

	[objc.kVK_ANSI_Keypad0] = 'num0',
	[objc.kVK_ANSI_Keypad1] = 'num1',
	[objc.kVK_ANSI_Keypad2] = 'num2',
	[objc.kVK_ANSI_Keypad3] = 'num3',
	[objc.kVK_ANSI_Keypad4] = 'num4',
	[objc.kVK_ANSI_Keypad5] = 'num5',
	[objc.kVK_ANSI_Keypad6] = 'num6',
	[objc.kVK_ANSI_Keypad7] = 'num7',
	[objc.kVK_ANSI_Keypad8] = 'num8',
	[objc.kVK_ANSI_Keypad9] = 'num9',
	[objc.kVK_ANSI_KeypadDecimal]  = 'num.',
	[objc.kVK_ANSI_KeypadMultiply] = 'num*',
	[objc.kVK_ANSI_KeypadPlus]     = 'num+',
	[objc.kVK_ANSI_KeypadMinus]    = 'num-',
	[objc.kVK_ANSI_KeypadDivide]   = 'num/',
	[objc.kVK_ANSI_KeypadEquals]   = 'num=',     --mac keyboard
	[objc.kVK_ANSI_KeypadEnter]    = 'numenter',
	[objc.kVK_ANSI_KeypadClear]    = 'numclear', --mac keyboard; 'numlock' key on win keyboard

	[objc.kVK_Mute]       = 'mute',
	[objc.kVK_VolumeDown] = 'volumedown',
	[objc.kVK_VolumeUp]   = 'volumeup',

	[110] = 'menu', --win keyboard

	[objc.kVK_F13] = 'F11', --taken (show desktop)
	[objc.kVK_F14] = 'F12', --taken (show the wachamacalit wall with the calendar and clock)
	[objc.kVK_F13] = 'F13', --mac keyboard; win keyboard 'printscreen' key
	[objc.kVK_F14] = 'F14', --mac keyboard; win keyboard 'scrolllock' key; taken (brightness down)
	[objc.kVK_F15] = 'F15', --mac keyboard; win keyboard 'break' key; taken (brightness up)
	[objc.kVK_F16] = 'F16', --mac keyboard
	[objc.kVK_F17] = 'F17', --mac keyboard
	[objc.kVK_F18] = 'F18', --mac keyboard
	[objc.kVK_F15] = 'F19', --mac keyboard
}

local keycodes = glue.index(keynames)

local function modifier_flag(mask, flags)
	flags = flags or tonumber(objc.NSEvent:modifierFlags())
	return bit.band(flags, mask) ~= 0
end

local function capslock_state(flags)
	return modifier_flag(objc.NSAlphaShiftKeyMask, flags)
end

local keystate
local capsstate

function NWWindow:reset_keystate()
	--note: platform-dependent flagbits are not given with NSEvent:modifierFlags() nor with GetKeys(),
	--so we can't get the initial state of specific modifier keys.
	keystate = {}
	capsstate = capslock_state()
end

local function keyname(event)
	local keycode = event:keyCode()
	return keynames[keycode]
end

function NWWindow:keyDown(event)
	local key = keyname(event)
	if not key then return end
	if not event:isARepeat() then
		self.api:_backend_keydown(key)
	end
	self.api:_backend_keypress(key)
end

function NWWindow:keyUp(event)
	local key = keyname(event)
	if not key then return end
	if key == 'help' then --simulate the missing keydown for the help/insert key
		self.api:_backend_keydown(key)
	end
	self.api:_backend_keyup(key)
end

local flagbits = {
	--undocumented bits tested on a macbook with US keyboard
	lctrl    = 2^0,
	lshift   = 2^1,
	rshift   = 2^2,
	lcommand = 2^3, --'lwin' key on PC keyboard
	rcommand = 2^4, --'rwin' key on PC keyboard; 'altgr' key on german PC keyboard
	lalt     = 2^5,
	ralt     = 2^6,
	--bits for PC keyboard
	rctrl    = 2^13,
}

function NWWindow:flagsChanged(event)
	--simulate key pressing for capslock
	local newcaps = capslock_state()
	local oldcaps = capsstate
	if newcaps ~= oldcaps then
		capsstate = newcaps
		keystate.capslock = true
		self.api:_backend_keydown'capslock'
		keystate.capslock = false
		self.api:_backend_keyup'capslock'
	end

	--detect keydown/keyup state change for modifier keys
	local flags = tonumber(event:modifierFlags())
	for name, mask in pairs(flagbits) do
		local oldstate = keystate[name] or false
		local newstate = bit.band(flags, mask) ~= 0
		if oldstate ~= newstate then
			keystate[name] = newstate
			if newstate then
				self.api:_backend_keydown(name)
				self.api:_backend_keypress(name)
			else
				self.api:_backend_keyup(name)
			end
		end
	end
end

local alt_names = { --ambiguous keys that have a single physical key mapping on mac
	left     = 'left!',
	up       = 'up!',
	right    = 'right!',
	down     = 'down!',
	pageup   = 'pageup!',
	pagedown = 'pagedown!',
	['end']  = 'end!',
	home     = 'home!',
	insert   = 'insert!',
	delete   = 'delete!',
	enter    = 'enter!',
}

local keymap, pkeymap

function window:key(name)
	if name == '^capslock' then
		return capsstate
	elseif name == 'capslock' then
		return keystate.capslock
	elseif name == 'shift' then
		return keystate.lshift or keystate.rshift or false
	elseif name == 'ctrl' then
		return keystate.lctrl or keystate.rctrl or false
	elseif name == 'alt' then
		return keystate.lalt or keystate.ralt or false
	elseif name == 'command' then
		return keystate.lcommand or keystate.rcommand or false
	elseif flagbits[name] then --get modifier saved state
		return keystate[name] or false
	else --get normal key state
		local keycode = keycodes[name] or keycodes[alt_names[name]]
		if not keycode then return false end
		keymap  = keymap or ffi.new'unsigned char[16]'
		pkeymap = pkeymap or ffi.cast('void*', keymap)
		objc.GetKeys(pkeymap)
		return bit.band(bit.rshift(keymap[bit.rshift(keycode, 3)], bit.band(keycode, 7)), 1) ~= 0
	end
end

--mouse

function NWWindow:setmouse(event)
	local m = self.api.mouse
	local pos = event:locationInWindow()
	m.x, m.y = self:flip_y(pos.x, pos.y)
	local btns = tonumber(event:pressedMouseButtons())
	m.left = bit.band(btns, 1) ~= 0
	m.right = bit.band(btns, 2) ~= 0
	m.middle = bit.band(btns, 4) ~= 0
	m.ex1 = bit.band(btns, 8) ~= 0
	m.ex2 = bit.band(btns, 16) ~= 0
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

local other_buttons = {'', 'middle', 'ex1', 'ex2'}

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
