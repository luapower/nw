local glue = require'glue'
local nw = require'nw'

local app = nw:app()

local win1 = app:window{x = 100, y = 100, w = 800, h = 400, title = 'win'}

win1:hide()

app:run()
