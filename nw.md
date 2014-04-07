---
project:   nw
tagline:   native widgets
platforms: mingw32, mingw64
---

#### NOTE: work-in-progress (to-be-released soon)

## `local nw = require'nw'`

Cross-platform library for displaying native windows, drawing their contents using [cairo] or [opengl],
and accessing keyboard, mouse and touchpad events in a consistent manner across Windows, Linux and OS X.

----------------------------------------- -----------------------------------------------------------------------------
__application__
`nw:app() -> app`									create an application
`app:run()`											run the application main loop
`app:quit()`										close all windows and end the application main loop
`app:screen_rect() -> x, y, w, h`			screen rectangle
`app:client_rect() -> x, y, w, h`			desktop rectangle (without taskbar)
`app:time() -> time`								get an opaque time object representing a hi-resolution timestamp
`app:timediff(time1, time2) -> ms`			get the difference between two time objects
__windows__
`app:window(options_t) -> win`				create a window (see below for options)
__options_t__
x, y, w, h (required)							window's frame (i.e. outside) rectangle
title (empty) 										window title
state ('normal')									'normal' | 'maximized' | 'minimized' | 'fullscreen'
topmost (false)									allways on top window
frame (true)										the window has a frame border and title bar
allow_minimize (true)							show the minimize button and allow minimization
allow_maximize (true)							show the maximize button and allow maximization
allow_close (true)								enable the close button and allow the window to be closed
allow_resize (true)								the window is resizeable
__lifetime__
`app:windows() -> iter() -> win`				iterate app's windows
`app:active_window() -> win`					get the active window
`app:active() -> true|false`					check if app is active
`win:free()`										close and free a window
`win:dead() -> true|false`						check if the window was free'd
`win:closing() -> [false]`						event: window is closing; return false to prevent it
`win:closed()`										event: window was closed (but not yet freed and its children are alive)
__activation__
`win:activate()`									activate the window
`win:active() -> true|false`					check if the window is active
`win:activated()`									event: window was activated
`win:deactivated()` 								event: window was deactivated
__state__
`win:show([state])`								show it (in its current state or in a new state)
`win:hide()`										hide it
`win:visible() -> true|false`					check if the window is visible
`win:state_changed()`							event: window's state has changed
__positioning__
`win:frame_rect([x], [y], [w],` \			change/return the frame rectangle
`[h]) -> x, y, w, h`
`win:frame_changing(how, x, y, w, h)`		event: frame rect is changing; how = move|left|right|top|bottom|topleft|topright|bottomleft|bottomright
`win:moved()`										event: window was moved
`win:resized()`									event: window was resized
`win:title([newtitle]) -> newtitle`			get/set the window's title
__keyboard__
`win:key(keyname) -> down[, toggled]`		key and toggle state (see source for key names)
`win:key_down(key)`								event: key down
`win:key_up(key)`									event: key up
`win:key_press(key)`								event: sent on each key down, including repeats
`win:key_char(char)`								event: sent after key_press for displayable characters; char is utf-8
__mouse__
`win:mouse_move(x, y)`							event: mouse move
`win:mouse_enter()`								event: mouse entered the client area of the window
`win:mouse_leave()`								event: mouse left the client area of the window
`win:mouse_down(button)`						event: a mouse button was pressed; button = 'left'|'right'|'middle'|'xbutton1'|'xbutton2'
`win:mouse_up(button)`							event: a mouse button was depressed
`win:mouse_click(button, count)`				event: a mouse button was clicked (pressed repeatedly); \
														return false to end the repeat chain (see notes)
`win:mouse_wheel(delta)`						event: mouse wheel
`win:mouse_hwheel(delta)`						event: mouse horizontal wheel
__rendering__
`win:render()`										event: draw the window contents
`win:invalidate()`								trigger window redrawing
----------------------------------------- -----------------------------------------------------------------------------

## Features

  * consistent behavior accross Windows, Linux and OS X
  * magnetized windows
  * transparent windows
  * full screen mode
  * complete access to the US keyboard
  * triple-click and n-click events
  * utf-8 strings

## Example

~~~{.lua}
local nw = require'nw'

local app = nw:app()

local win = app:window{x = 100, y = 100, w = 400, h = 200, title = 'hello'}

function win:mouse_click(button, count)
	if button == 'left' and count == 3 then --triple click
		app:quit()
	end
end

function win:key_down(key)
	if key == 'F11' then
		if self:state'fullscreen' then
			self:show'normal'
		else
			self:show'fullscreen'
		end
	end
end

app:run() --start the main loop

~~~

## Notes

### n-click feature

...

