io.stdout:setvbuf'no'
local glue = require'glue'
local ffi = require'ffi'
local objc = require'objc'
--objc.debug = true
local bs = require'objc.BridgeSupport'
bs.loadFramework'Foundation'
bs.loadFramework'AppKit'
bs.loadFramework'System'
bs.loadFramework'CoreServices'

local pool = objc.NSAutoreleasePool:new()

--app class

local nsappclass = objc.createClass(objc.NSApplication, 'NSApp', {})

objc.addMethod(nsappclass, objc.SEL'applicationShouldTerminate:', function(_, sel, app)
	print'terminate?'
	return true
end, 'B@:@')

objc.addMethod(nsappclass, objc.SEL'applicationShouldTerminateAfterLastWindowClosed:', function(_, sel, app)
	print'terminate after last win closed?'
	return false
end, 'B@:@')

--app

local nsapp = nsappclass:sharedApplication()
nsapp.delegate = nsapp
nsapp:setActivationPolicy(bs.NSApplicationActivationPolicyRegular)

local nsrapp = objc.NSRunningApplication:currentApplication()

--win

local function newwin(x, y, title)
	local nswinclass = objc.createClass(objc.NSWindow, 'NSWindow_'..title, {})

	objc.addMethod(nswinclass, objc.SEL'windowShouldClose:', function(nswin, sel, sender)
		print(title, 'closing')
		return true
	end, 'B@:@')

	objc.addMethod(nswinclass, objc.SEL'windowWillClose:', function(nswin, sel, notification)
		print(title, 'closed')
		nsapp:terminate(nil)
	end, 'v@:@')

	objc.addMethod(nswinclass, objc.SEL'windowDidBecomeKey:', function(nswin, sel, notification)
		print(title, 'activated')
	end, 'v@:@')

	objc.addMethod(nswinclass, objc.SEL'windowDidResignKey:', function(nswin, sel, notification)
		print(title, 'deactivated')
	end, 'v@:@')

	local nswin = nswinclass:alloc():initWithContentRect_styleMask_backing_defer(
						{{x, y}, {600, 300}},
						bit.bor(
							bs.NSTitledWindowMask,
							bs.NSClosableWindowMask,
							bs.NSMiniaturizableWindowMask,
							bs.NSResizableWindowMask),
						--t.frame == 'none' and bit.bor(bs.NSBorderlessWindowMask) or
						--t.frame == 'transparent' and bit.bor(bs.NSBorderlessWindowMask), --TODO
						bs.NSBackingStoreBuffered,
						false)

	nswin.delegate = nswin

	nswin:setTitle(objc.NSStr(title))

	return nswin
end

local win1 = newwin(100, 200, 'win1')
--win1:makeKeyWindow()
--win1:miniaturize(nil)
--win1:orderOut(nil)
--win1:zoom(nil)

local win2 = newwin(200, 100, 'win2')
--win2:makeKeyWindow()
--win2:miniaturize(nil)
--win2:orderOut(nil)
--win2:zoom(nil)

--run

nsapp:activateIgnoringOtherApps(true)
win1:makeKeyAndOrderFront(nil)
win2:makeKeyAndOrderFront(nil)
win1:makeKeyWindow()

print(win1:isKeyWindow() ~= 0, win2:isKeyWindow() ~= 0)
--win2:orderOut(nil)
--print(win1:isVisible() ~= 0, win2:isVisible() ~= 0)

--nsrapp:activateWithOptions(bs.NSApplicationActivateAllWindows)
nsapp:run()

