--native widgets cococa backend (Cosmin Apreutesei, public domain).

--COCOA NOTES
-------------
--windows are created hidden by default.
--zoom()'ing a hidden window does not show it, but does change its maximized flag.
--orderOut() doesn't hide a window if it's the key window, instead it disables mouse on it making it appear frozen.
--makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--makeKeyAndOrderFront() is ignored if the window is hidden.
--isVisible() returns false both when the window is orderOut() and when it's minimized().
--windows created after calling activateIgnoringOtherApps(false) go behind the active app.
--windows created after calling activateIgnoringOtherApps(true) go in front of the active app.
--windows activated while the app is inactive will go in front when activateIgnoringOtherApps(true) is called,
--but other windows will not, unlike clicking the dock icon. this is hysterical.
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
--makeKeyAndOrderFront() is deferred to after the message loop is started, after which a single windowDidBecomeKey
--is triggered on the last window made key (unlike windows which activates/deactivates windows as it happens).
--makeKeyAndOrderFront() is also deferred, if the app is not active, for when it becomes active.
--applicationDidResignActive() is not sent on exit.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local objc = require'objc'
local box2d = require'box2d'
local cbframe = require'cbframe'

objc.debug.cbframe = true --use cbframe for problem callbacks
objc.load'Foundation'
objc.load'AppKit'
objc.load'System' --for mach_absolute_time
objc.load'Carbon.HIToolbox' --for key codes
objc.load'CoreGraphics' --for CGWindow*
objc.load'CoreFoundation' --for CFArray

local function unpack_nsrect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local function override_rect(x, y, w, h, x1, y1, w1, h1)
	return x1 or x, y1 or y, w1 or w, h1 or h
end

--convert rect from bottom-up relative-to-main-screen space to top-down relative-to-main-screen space
local function flip_screen_rect(main_h, x, y, w, h)
	main_h = main_h or objc.NSScreen:mainScreen():frame().size.height
	return x, main_h - h - y, w, h
end

local nw = {name = 'cocoa'}

--os version -----------------------------------------------------------------

function nw:os()
	local s = objc.tolua(objc.NSProcessInfo:processInfo():operatingSystemVersionString()) --OSX 10.2+
	return 'OSX '..(s:match'%d+%.%d+%.%d+')
end

--app object -----------------------------------------------------------------

local app = {}

function nw:app(frontend)
	return app:_new(frontend)
end

local App = objc.class('App', 'NSApplication <NSApplicationDelegate>')

function app:_new(frontend)

	self = glue.inherit({frontend = frontend}, self)

	--create the default autorelease pool for small objects.
	self.pool = objc.NSAutoreleasePool:new()

	--TODO: we have to reference mainScreen() before using any of the the display functions,
	--or we will get errors on [NSRecursiveLock unlock].
	objc.NSScreen:mainScreen()

	self.nsapp = App:sharedApplication()
	self.nsapp.frontend = frontend
	self.nsapp.backend = self

	self.nsapp:setDelegate(self.nsapp)

	--set it to be a normal app with dock and menu bar
	self.nsapp:setActivationPolicy(objc.NSApplicationActivationPolicyRegular)

	--disable mouse coalescing so that mouse move events are not skipped.
	objc.NSEvent:setMouseCoalescingEnabled(false)

	--activate the app before windows are created.
	self:activate()

	return self
end

--message loop ---------------------------------------------------------------

function app:run()
	self.nsapp:run()
end

function app:stop()
	self.nsapp:stop(nil)
	--post a dummy event to ensure the stopping
	local event = objc.NSEvent:
		otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
			objc.NSApplicationDefined, objc.NSMakePoint(0,0), 0, 0, 0, nil, 1, 1, 1)
	self.nsapp:postEvent_atStart(event, true)
end

--quitting -------------------------------------------------------------------

function App:applicationShouldTerminate()
	self.frontend:_backend_quitting() --calls quit() which calls stop().
	--we never terminate the app, we just stop the loop instead.
	return false
end

--time -----------------------------------------------------------------------

function app:time()
	return objc.mach_absolute_time()
end

local timebase
function app:timediff(start_time, end_time)
	if not timebase then
		timebase = ffi.new'mach_timebase_info_data_t'
		objc.mach_timebase_info(timebase)
	end
	return tonumber(end_time - start_time) * timebase.numer / timebase.denom / 10^6
end

--timers ---------------------------------------------------------------------

objc.addmethod('App', 'nw_timerEvent', function(self, timer)
	if not timer.nw_func then return end
	if timer.nw_func() == false then
		timer:invalidate()
		timer.nw_func = nil
	end
end, 'v@:@')

function app:runevery(seconds, func)
	local timer = objc.NSTimer:scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
		seconds, self.nsapp, 'nw_timerEvent', nil, true)
	timer.nw_func = func
end

--windows --------------------------------------------------------------------

local window = {}

function app:window(frontend, t)
	return window:_new(self, frontend, t)
end

local nswin_map = {} --nswin->window

local Window = objc.class('Window', 'NSWindow <NSWindowDelegate>')
local View = objc.class('View', 'NSView')

function window:_new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local style = t.frame == 'normal' and bit.bor(
							objc.NSTitledWindowMask,
							t.closeable and objc.NSClosableWindowMask or 0,
							t.minimizable and objc.NSMiniaturizableWindowMask or 0,
							t.resizeable and objc.NSResizableWindowMask or 0) or
						t.frame == 'none' and bit.bor(objc.NSBorderlessWindowMask) or
						t.frame == 'transparent' and bit.bor(objc.NSBorderlessWindowMask) --TODO

	local frame_rect = objc.NSMakeRect(flip_screen_rect(nil, t.x, t.y, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	self.nswin = Window:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)
	ffi.gc(self.nswin, nil) --disown, the user owns it now

	self.nswin.frontend = frontend
	self.nswin.backend = self
	self.nswin.app = app

	nswin_map[objc.nptr(self.nswin)] = self.frontend

	local view = View:alloc():initWithFrame(objc.NSMakeRect(0, 0, 100, 100))
	self.nswin:setContentView(view)
	ffi.gc(view, nil) --disown, nswin owns it now

	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end
	if t.edgesnapping then
		self.nswin:setMovable(false)
	end
	if t.fullscreenable and nw.frontend:os'OSX 10.7' then
		self.nswin:setCollectionBehavior(bit.bor(tonumber(self.nswin:collectionBehavior()),
			objc.NSWindowCollectionBehaviorFullScreenPrimary)) --OSX 10.7+
	end
	if not t.maximizable then
		if not t.minimizable then
			--hide the minimize and maximize buttons when they're both disabled
			--to emulate Windows behavior.
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setHidden(true)
			self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
		else
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setEnabled(false)
		end
	end
	self.nswin:setTitle(t.title)

	self.nswin:reset_keystate()

	local opts = bit.bor(
		objc.NSTrackingActiveInKeyWindow,
		objc.NSTrackingInVisibleRect,
		objc.NSTrackingMouseEnteredAndExited,
		objc.NSTrackingMouseMoved,
		objc.NSTrackingCursorUpdate)
	local rect = self.nswin:contentView():bounds()
	local area = objc.NSTrackingArea:alloc():initWithRect_options_owner_userInfo(
		rect, opts, self.nswin:contentView(), nil)
	self.nswin:contentView():addTrackingArea(area)

	self.nswin:setBackgroundColor(objc.NSColor:redColor()) --TODO: remove

	if t.maximized then
		if not self:maximized() then
			self.nswin:zoom(nil)
		end
	end

	--enable events
	self.nswin:setDelegate(self.nswin)

	self._show_minimized = t.minimized --minimize on the next show()
	self._show_fullscreen = t.fullscreen --fullscreen on the next show()
	self._visible = false

	return self
end

--closing --------------------------------------------------------------------

function window:forceclose()
	self.nswin:close() --doesn't call windowShouldClose
end

function Window:windowShouldClose()
	return self.frontend:_backend_closing() or false
end

function Window:nw_close()
	self.frontend:_backend_closed()
	nswin_map[objc.nptr(self)] = nil
	self.backend.nswin = nil
end

function Window:windowWillClose()
	--defer closing on deactivation so that 'deactivated' event is sent before the 'closed' event
	if self.backend:active() then
		self._close_on_deactivate = true
	else
		self:nw_close()
	end
end

--activation -----------------------------------------------------------------

function app:activate()
	self.nsapp:activateIgnoringOtherApps(true)
end

function app:active_window()
	return nswin_map[objc.nptr(self.nsapp:keyWindow())]
end

function app:active()
	return self.nsapp:isActive()
end

function App:applicationWillBecomeActive()
	self.frontend:_backend_activated()
end

function App:applicationDidResignActive()
	self.frontend:_backend_deactivated()
end

function Window:windowDidBecomeKey()
	self:reset_keystate()
	self.frontend:_backend_activated()
end

function Window:windowDidResignKey()
	self.dragging = false
	self:reset_keystate()
	self.frontend:_backend_deactivated()

	--check for deferred close
	if self._close_on_deactivate then
		self:nw_close()
	end
end

function window:activate()
	self.nswin:makeKeyAndOrderFront(nil)
end

function window:active()
	return self.nswin:isKeyWindow()
end

function Window:canBecomeKeyWindow()
	--this is because windows with NSBorderlessWindowMask can't become key by default.
	return true
end

function Window:canBecomeMainWindow()
	--this is because windows with NSBorderlessWindowMask can't become main by default.
	return true
end

--state ----------------------------------------------------------------------

function window:show()
	self._visible = true
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
	if self:fullscreen() then
		self:fullscreen(false)
	elseif self:maximized() then
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
	--self.nswin:makeKeyAndOrderFront(nil)
	self.nswin:toggleFullScreen(nil)
end

function window:_exit_fullscreen(show_maximized)
	self.nswin:toggleFullScreen(nil)
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

function Window:windowWillEnterFullScreen()
	self.nw_stylemask = self:styleMask()
	self.nw_frame = self:frame()
	self:setStyleMask(bit.bor(
		objc.NSFullScreenWindowMask,
		objc.NSBorderlessWindowMask
	))
	self:setFrame_display(self:screen():frame(), true)
end

function Window:windowWillExitFullScreen()
	self:setStyleMask(self.nw_stylemask)
	self:setFrame_display(self.nw_frame, true)
end

--positioning ----------------------------------------------------------------

function app:_getmagnets(around_nswin)
	local t = {} --{{x=, y=, w=, h=}, ...}

	local opt = bit.bor(
		objc.kCGWindowListOptionOnScreenOnly,
		objc.kCGWindowListExcludeDesktopElements)

	local nswin_number = tonumber(around_nswin:windowNumber())
	local list = objc.CGWindowListCopyWindowInfo(opt, nswin_number) --front-to-back order assured

	--a glimpse into the mind of a Cocoa programmer...
	local bounds = ffi.new'CGRect[1]'
	for i = 0, tonumber(objc.CFArrayGetCount(list)-1) do
		local entry = ffi.cast('id', objc.CFArrayGetValueAtIndex(list, i)) --entry is NSDictionary
		local sharingState = entry:objectForKey(ffi.cast('id', objc.kCGWindowSharingState)):intValue()
		if sharingState ~= objc.kCGWindowSharingNone then --filter out windows we can't read from
			local layer = entry:objectForKey(ffi.cast('id', objc.kCGWindowLayer)):intValue()
			local number = entry:objectForKey(ffi.cast('id', objc.kCGWindowNumber)):intValue()
			if layer <= 0 and number ~= nswin_number then --ignore system menu, dock, etc.
				local boundsEntry = entry:objectForKey(ffi.cast('id', objc.kCGWindowBounds))
				objc.CGRectMakeWithDictionaryRepresentation(ffi.cast('CFDictionaryRef', boundsEntry), bounds)
				local x, y, w, h = unpack_nsrect(bounds[0]) --already flipped
				t[#t+1] = {x = x, y = y, w = w, h = h}
			end
		end
	end

	objc.CFRelease(ffi.cast('id', list))

	return t
end

function app:magnets(around_nswin)
	if not self._magnets then
		self._magnets = self:_getmagnets(around_nswin)
	end
	return self._magnets
end

function window:magnets()
	return self.app:magnets(self.nswin)
end

function Window:nw_clientarea_hit(event)
	local mp = event:locationInWindow()
	local rc = self:contentView():bounds()
	return box2d.hit(mp.x, mp.y, unpack_nsrect(rc))
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
function Window:nw_titlebar_buttons_hit(event)
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

function Window:nw_resize_area_hit(event)
	local mp = event:locationInWindow()
	local _, _, w, h = unpack_nsrect(self:frame())
	return resize_area_hit(mp.x, mp.y, w, h)
end

function Window:edgesnapping(snapping)
	self.nswin:setMovable(not snapping)
end

function Window:sendEvent(event)
	if self.frontend:edgesnapping() then
		--take over window dragging by the titlebar so that we can post moving events
		local etype = event:type()
		if self.dragging then
			if etype == objc.NSLeftMouseDragged then
				self:setmouse(event)
				local mx = self.frontend._mouse.x - self.dragoffset_x
				local my = self.frontend._mouse.y - self.dragoffset_y
				local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
				x = x + mx
				y = y + my
				local x1, y1, w1, h1 = self.frontend:_backend_resizing('move', x, y, w, h)
				if x1 or y1 or w1 or h1 then
					self:setFrame_display(objc.NSMakeRect(flip_screen_rect(nil,
						override_rect(x, y, w, h, x1, y1, w1, h1))), false)
				else
					self:setFrameOrigin(mp)
				end
				return
			elseif etype == objc.NSLeftMouseUp then
				self.dragging = false
				self.mousepos = nil
				self.app._magnets = nil --clear magnets
				return
			end
		elseif etype == objc.NSLeftMouseDown
			and not self:nw_clientarea_hit(event)
			and not self:nw_titlebar_buttons_hit(event)
			and not self:nw_resize_area_hit(event)
		then
			self:setmouse(event)
			self:makeKeyAndOrderFront(nil)
			self.app.nsapp:activateIgnoringOtherApps(true)
			self.dragging = true
			self.dragoffset_x = self.frontend._mouse.x
			self.dragoffset_y = self.frontend._mouse.y
			return
		elseif etype == objc.NSLeftMouseDown then
			self:makeKeyAndOrderFront(nil)
			self.mousepos = event:locationInWindow() --for resizing
		end
	end
	objc.callsuper(self, 'sendEvent', event)
end

function Window:windowWillStartLiveResize()
	if not self.mousepos then
		self.mousepos = self:mouseLocationOutsideOfEventStream()
	end
	local mx, my = self.mousepos.x, self.mousepos.y
	local _, _, w, h = unpack_nsrect(self:frame())
	self.how = resize_area_hit(mx, my, w, h)
	self.app._magnets = nil --clear magnets
	self.frontend:_backend_start_resize()
end

function Window:windowDidEndLiveResize()
	self.frontend:_backend_end_resize()
end

function Window:nw_resizing(w_, h_)
	if not self.how then return w_, h_ end
	local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
	if self.how:find'top' then y, h = y + h - h_, h_ end
	if self.how:find'bottom' then h = h_ end
	if self.how:find'left' then x, w = x + w - w_, w_ end
	if self.how:find'right' then w = w_ end
	local x1, y1, w1, h1 = self.frontend:_backend_resizing(self.how, x, y, w, h)
	if x1 or y1 or w1 or h1 then
		x, y, w, h = flip_screen_rect(nil, override_rect(x, y, w, h, x1, y1, w1, h1))
	end
	return w, h
end

function Window.windowWillResize_toSize(cpu)
	if ffi.arch == 'x64' then
		--RDI = self, XMM0 = NSSize.x, XMM1 = NSSize.y
		local self = ffi.cast('id', cpu.RDI.p)
		local w = cpu.XMM[0].lo.f
		local h = cpu.XMM[1].lo.f
		w, h = self:nw_resizing(w, h)
		--return double-only structs <= 8 bytes in XMM0:XMM1
		cpu.XMM[0].lo.f = w
		cpu.XMM[1].lo.f = h
	else
		--ESP[1] = self, ESP[2] = selector, ESP[3] = sender, ESP[4] = NSSize.x, ESP[5] = NSSize.y
		local self = ffi.cast('id', cpu.ESP.dp[1].p)
		w = cpu.ESP.dp[4].f
		h = cpu.ESP.dp[5].f
		w, h = self:nw_resizing(w, h)
		--return values <= 8 bytes in EAX:EDX
		cpu.EAX.f = w
		cpu.EDX.f = h
	end
end

function Window:windowDidResize()
	self.frontend:_backend_resized()
end

--displays -------------------------------------------------------------------

function app:_display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_screen_rect(main_h, unpack_nsrect(screen:frame()))
	t.client_x, t.client_y, t.client_w, t.client_h = flip_screen_rect(main_h, unpack_nsrect(screen:visibleFrame()))
	return self.frontend:_display(t)
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
		table.insert(displays, self:_display(main_h, screens:objectAtIndex(i)))
	end
	return displays
end

function app:main_display()
	local screen = objc.NSScreen:mainScreen()
	return self:_display(nil, screen)
end

function app:display_count()
	return objc.NSScreen:screens():count()
end

function window:display()
	return self.app:_display(nil, self.nswin:screen())
end

function App:applicationDidChangeScreenParameters()
	self.frontend:_backend_displays_changed()
end

--cursors --------------------------------------------------------------------

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

function Window:cursorUpdate(event)
	if self:nw_clientarea_hit(event) then
		setcursor(self.backend._cursor)
	else
		objc.callsuper(self, 'cursorUpdate', event)
	end
end

--frame

function window:title(title)
	if title then
		self.nswin:setTitle(title)
	else
		return objc.tolua(self.nswin:title())
	end
end

function window:topmost(topmost)
	if topmost ~= nil then
		self.backend.topmost = topmost
	else
		return self.backend.topmost
	end
end

--keyboard -------------------------------------------------------------------

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

function Window:reset_keystate()
	--note: platform-dependent flagbits are not given with NSEvent:modifierFlags() nor with GetKeys(),
	--so we can't get the initial state of specific modifier keys.
	keystate = {}
	capsstate = capslock_state()
end

local function keyname(event)
	local keycode = event:keyCode()
	return keynames[keycode]
end

function Window:keyDown(event)
	local key = keyname(event)
	if not key then return end
	if not event:isARepeat() then
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keypress(key)
end

function Window:keyUp(event)
	local key = keyname(event)
	if not key then return end
	if key == 'help' then --simulate the missing keydown for the help/insert key
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keyup(key)
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

function Window:flagsChanged(event)
	--simulate key pressing for capslock
	local newcaps = capslock_state()
	local oldcaps = capsstate
	if newcaps ~= oldcaps then
		capsstate = newcaps
		keystate.capslock = true
		self.frontend:_backend_keydown'capslock'
		keystate.capslock = false
		self.frontend:_backend_keyup'capslock'
	end

	--detect keydown/keyup state change for modifier keys
	local flags = tonumber(event:modifierFlags())
	for name, mask in pairs(flagbits) do
		local oldstate = keystate[name] or false
		local newstate = bit.band(flags, mask) ~= 0
		if oldstate ~= newstate then
			keystate[name] = newstate
			if newstate then
				self.frontend:_backend_keydown(name)
				self.frontend:_backend_keypress(name)
			else
				self.frontend:_backend_keyup(name)
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

--mouse ----------------------------------------------------------------------

function app:double_click_time() --milliseconds
	return objc.NSEvent:doubleClickInterval() * 1000
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

function Window:setmouse(event)
	local m = self.frontend._mouse
	local pos = event:locationInWindow()
	m.x = pos.x
	m.y = self:contentView():frame().size.height - pos.y --flip y around contentView's height
	local btns = tonumber(event:pressedMouseButtons())
	m.left = bit.band(btns, 1) ~= 0
	m.right = bit.band(btns, 2) ~= 0
	m.middle = bit.band(btns, 4) ~= 0
	m.ex1 = bit.band(btns, 8) ~= 0
	m.ex2 = bit.band(btns, 16) ~= 0
	return m
end

function Window:mouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('left', m.x, m.y)
end

function Window:mouseUp(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup('left', m.x, m.y)
end

function Window:rightMouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('right', m.x, m.y)
end

function Window:rightMouseUp(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup('right', m.x, m.y)
end

local other_buttons = {'', 'middle', 'ex1', 'ex2'}

function Window:otherMouseDown(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown(btn, m.x, m.y)
end

function Window:otherMouseUp(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.frontend:_backend_mouseup(btn, m.x, m.y)
end

function Window:mouseMoved(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousemove(m.x, m.y)
end

function Window:mouseDragged(event)
	self:mouseMoved(event)
end

function Window:rightMouseDragged(event)
	self:mouseMoved(event)
end

function Window:otherMouseDragged(event)
	self:mouseMoved(event)
end

function Window:mouseEntered(event)
	self:setmouse(event)
	self.frontend:_backend_mouseenter()
end

function Window:mouseExited(event)
	self:setmouse(event)
	self.frontend:_backend_mouseleave()
end

function Window:scrollWheel(event)
	local m = self:setmouse(event)
	local dx = event:deltaX()
	if dx ~= 0 then
		self.frontend:_backend_mousehwheel(dx, x, y)
	end
	local dy = event:deltaY()
	if dy ~= 0 then
		self.frontend:_backend_mousewheel(dy, x, y)
	end
end

function window:mouse_pos()
	--return objc.NSEvent:
end

--rendering ------------------------------------------------------------------

--TODO

--menus ----------------------------------------------------------------------

local menu = {}

function app:menu()
	return menu:_new(self)
end

function menu:_new(app)
	local nsmenu = objc.NSMenu:new()
	local self = glue.inherit({app = app, nsmenu = nsmenu}, menu)
	nsmenu.nw_backend = self
	return self
end

local function menuitem(args, menutype)
	--zero or more '-' means separator (not for menu bars)
	local separator = menutype ~= 'menubar' and
		args.text:find'^%-*$' and true or nil
	return {
		text = args.text,
		on_click = args.action,
		submenu = args.submenu and args.submenu.backend.winmenu,
		checked = args.checked,
		separator = separator,
	}
end

local function dump_menuitem(mi)
	return {
		text = mi.separator and '' or mi.text,
		action = mi.submenu and mi.submenu.nw_backend.frontend or mi.on_click,
		checked = mi.checked,
	}
end

objc.addmethod('App', 'nw_menuItemClicked', function(self, item)
	item.nw_action()
end, 'v@:@')

local function menuitem(args)
	local item = NWMenuItem:new()
	item:setTitle(args.text)
	item:setState(args.checked and objc.NSOnState or objc.NSOffState)
	if type(args.action) == 'function' then
		item:setTarget(self.app.nsapp)
		item:setAction'nw_menuItemClicked'
		item.nw_action = args.action
	end
	ffi.gc(item, nil)
	return item
end

local function dump_menuitem(item)
	return {
		--
	}
end

function menu:add(index, args)
	local item = menuitem(args)
	if index then
		self.nsmenu:insertItem_atIndex(item, index-1)
	else
		self.nsmenu:addItem(item)
	end
end

function menu:set(index, args)
	self.nsmenu:

end

function menu:get(index)
	return dump_menuitem(self.nsmenu:itemAtIndex(index-1))
end

function menu:item_count()
	return self.nsmenu:numberOfItems()
end

function menu:remove(index)
	self.nsmenu:removeItemAtIndex(index-1)
end

function menu:get_checked(index)
	return self.nsmenu:itemAtIndex(index-1):state() == objc.NSOnState
end

function menu:set_checked(index, checked)
	self.nsmenu:itemAtIndex(index-1):setState(checked and objc.NSOnState or objc.NSOffState)
end

function menu:get_enabled(index)
	return self.nsmenu:itemAtIndex(index-1):isEnabled()
end

function menu:set_enabled(index, enabled)
	self.nsmenu:itemAtIndex(index-1):setEnabled(enabled)
end

function window:menu()
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

--	local qmi = objc.NSMenuItem:alloc():initWithTitle_action_keyEquivalent('Quit', 'terminate:', 'q')
--	appmenu:addItem(qmi); ffi.gc(qmi, nil)

function window:menu()
	if not self.app._menu then
		local menubar = objc.NSMenu:new()
		local appmi = objc.NSMenuItem:new()
		menubar:addItem(appmi); ffi.gc(appmi, nil)
		nsapp:setMainMenu(menubar); ffi.gc(menubar, nil)
		local appmenu = objc.NSMenu:new()
		appmi:setSubmenu(appmenu); ffi.gc(appmenu, nil)
		self.app._menu = appmenu
	end
	return self.app._menu
end

function window:menu()
	--
end

--buttons --------------------------------------------------------------------



if not ... then require'nw_test' end

return nw
