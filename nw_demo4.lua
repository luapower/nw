local glue = require'glue'
local nw = require'nw'

local app = nw:app()

local win1 = app:window{x = 100, y = 100, w = 800, h = 400, title = 'win'}
local win2 = app:window{x = 200, y = 200, w = 800, h = 400, title = 'win2'}

events = glue.index{'closing', 'closed', 'activated', 'deactivated'}

local _event = win1.event
function win1:event(event, ...)
	if not events[event] then return end
	print('win1', event, ...)
	return _event(win1, event, ...)
end

local _event = win2.event
function win2:event(event, ...)
	if not events[event] then return end
	print('win2', event, ...)
	return _event(win2, event, ...)
end

--win:hide()
--win:minimize()
--win.impl.nswin:orderFront(nil)
--win:hide()
--win2:hide()
--print(win:visible())
--win2:minimize()

app:run()
