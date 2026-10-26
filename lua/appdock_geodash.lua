--[[--
Geometry Rush for AppDock: runs the "geodash" binary (GeometryRush + raylib software
renderer, see geodash/gd_shim.cpp) as a background process that publishes its picture
through a loopback-only VNC server, and shows that picture inside KOReader so KOReader
handles e-ink refresh and touch.

Touch: tapping the game picture = mouse click (the game jumps on left click).
Buttons below the picture: Jump (Space), Esc, Enter, Up, Down, R (restart), P (pause), Quit.

Files expected on the device (installed by geodash-kobo.zip):
  /mnt/onboard/.adds/geodash/bin/geodash
  /mnt/onboard/.adds/geodash/home/levels/*.txt

Usage from another AppDock file:
  local GD = require("appdock_geodash")
  GD.open()
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- ---------------------------------------------------------------- config ----
local GD_DIR = os.getenv("GD_DIR") or "/mnt/onboard/.adds/geodash"
local GD_LOG = GD_DIR .. "/geodash.log"
local GD_HOME = GD_DIR .. "/home"          -- working dir: levels/, mylevels/, settings.txt
local VNC_HOST, VNC_PORT = "127.0.0.1", 5963 -- must match scripts/03-geodash.sh
local POLL_INTERVAL = 0.08
local CONNECT_TIMEOUT = 20
-- KOReader refresh mode for game frames: "ui" (default), "partial", "fast" (A2, ghosty,
-- bad colours on Kaleido screens but the quickest).
local REFRESH_MODE = os.getenv("GD_REFRESH") or "ui"

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- ------------------------------------------------------------ RFB client ----
local function be16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
local function s32(s, i)
    local v = be32(s, i)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end
local function p16(v) v = math.floor(v); return string.char(math.floor(v / 256) % 256, v % 256) end
local function p32(v)
    v = math.floor(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256, v % 256)
end

local function bbStride(bb)
    local ok, v = pcall(function() return bb.stride end)
    if ok and v then return tonumber(v) end
    ok, v = pcall(function() return bb.pitch end)
    if ok and v then return tonumber(v) end
    return bb:getWidth() * 4
end

local RFB = {}
RFB.__index = RFB

function RFB:send(data)
    local i = 1
    while i <= #data do
        local sent, err, last = self.sock:send(data, i)
        if sent then
            i = sent + 1
        elseif last and last >= i then
            i = last + 1
        else
            error("rfb send: " .. tostring(err))
        end
    end
end

function RFB:read(n)
    if n == 0 then return "" end
    local parts, got = {}, 0
    while got < n do
        local data, err, partial = self.sock:receive(n - got)
        data = data or partial
        if data and #data > 0 then
            parts[#parts + 1] = data
            got = got + #data
        else
            error("rfb read: " .. tostring(err))
        end
    end
    return table.concat(parts)
end

function RFB:handshake()
    local ver = self:read(12)
    if not ver:match("^RFB 003%.%d%d%d\n$") then error("not an RFB server") end
    self:send("RFB 003.008\n")
    local n = self:read(1):byte()
    if n == 0 then error("rfb: server refused connection") end
    local types = self:read(n)
    local has_none = false
    for i = 1, n do if types:byte(i) == 1 then has_none = true end end
    if not has_none then error("rfb: server wants authentication") end
    self:send("\1")
    if be32(self:read(4), 1) ~= 0 then error("rfb: security handshake failed") end
    self:send("\1") -- shared session
    local init = self:read(24)
    self.w, self.h = be16(init, 1), be16(init, 3)
    self:read(be32(init, 21)) -- desktop name
    -- 32 bpp, depth 24, little endian, true colour, R in the lowest byte so the
    -- memory layout is R,G,B,pad like a KOReader RGB32 blitbuffer.
    self:send("\0\0\0\0" .. string.char(32, 24, 0, 1)
        .. p16(255) .. p16(255) .. p16(255) .. string.char(0, 8, 16) .. "\0\0\0")
    self:send("\2\0" .. p16(1) .. p32(0)) -- encodings: Raw only
    self.bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BBRGB32)
    self.bb:fill(Blitbuffer.COLOR_BLACK)
end

function RFB.connect(host, port)
    local socket = require("socket")
    local sock = socket.tcp()
    sock:settimeout(3)
    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, err
    end
    local self = setmetatable({ sock = sock }, RFB)
    local hs_ok, hs_err = pcall(self.handshake, self)
    if not hs_ok then
        sock:close()
        return nil, hs_err
    end
    return self
end

function RFB:close()
    if self.sock then pcall(self.sock.close, self.sock); self.sock = nil end
end

function RFB:requestUpdate(incremental)
    self:send("\3" .. string.char(incremental and 1 or 0)
        .. p16(0) .. p16(0) .. p16(self.w) .. p16(self.h))
end

function RFB:blit(x, y, w, h, data)
    local bb = self.bb
    local stride = bbStride(bb)
    local src = ffi.cast("const uint8_t*", data)
    for row = 0, h - 1 do
        if y + row >= self.h then break end
        local dst = bb.data + (y + row) * stride + x * 4
        ffi.copy(dst, src + row * w * 4, w * 4)
        for i = 0, w - 1 do dst[i * 4 + 3] = 255 end -- opaque alpha
    end
end

-- Returns nil (nothing pending), false (message handled, no pixels), or the
-- union rectangle {x0,y0,x1,y1} of changed pixels.
function RFB:poll()
    local socket = require("socket")
    local ready = socket.select({ self.sock }, nil, 0)
    if not ready or not ready[1] then return nil end
    local t = self:read(1):byte()
    if t == 0 then
        local n = be16(self:read(3), 2)
        local x0, y0, x1, y1
        for _ = 1, n do
            local rh = self:read(12)
            local x, y, w, h = be16(rh, 1), be16(rh, 3), be16(rh, 5), be16(rh, 7)
            if s32(rh, 9) ~= 0 then error("rfb: unsupported encoding") end
            self:blit(x, y, w, h, self:read(w * h * 4))
            x0 = x0 and math.min(x0, x) or x
            y0 = y0 and math.min(y0, y) or y
            x1 = x1 and math.max(x1, x + w) or (x + w)
            y1 = y1 and math.max(y1, y + h) or (y + h)
        end
        if x0 then return { x0, y0, x1, y1 } end
        return false
    elseif t == 2 then -- bell
        return false
    elseif t == 3 then -- server cut text
        self:read(be32(self:read(7), 4))
        return false
    end
    error("rfb: unexpected server message " .. tostring(t))
end

function RFB:pointer(x, y, mask)
    self:send("\5" .. string.char(mask) .. p16(math.max(0, x)) .. p16(math.max(0, y)))
end

function RFB:key(keysym, down)
    self:send("\4" .. string.char(down and 1 or 0) .. "\0\0" .. p32(keysym))
end

-- ---------------------------------------------------------- process mgmt ----
local Proc = { pid = nil }

local function binaryPath()
    local p = GD_DIR .. "/bin/geodash"
    if fileExists(p) then return p end
end

function Proc.available()
    if not binaryPath() then
        return false, _("Geometry Rush is not installed. Unzip geodash-kobo.zip into the Kobo root (see README).")
    end
    return true
end

function Proc.stop()
    os.execute("pkill -x geodash >/dev/null 2>&1")
    if Proc.pid then
        os.execute("kill -9 " .. tostring(Proc.pid) .. " >/dev/null 2>&1")
        Proc.pid = nil
    end
end

function Proc.start()
    Proc.stop()
    local exe = binaryPath()
    if not exe then return false end
    -- The VNC server binds to 127.0.0.1; some e-readers leave "lo" down, so bring it up.
    os.execute("ifconfig lo 127.0.0.1 netmask 255.0.0.0 up >/dev/null 2>&1 || ip link set lo up >/dev/null 2>&1")
    os.execute("mkdir -p " .. shq(GD_HOME))
    -- GD_OUT_W: the game picture is shrunk (integer factor) until it is at most this wide.
    local cmd = string.format(
        "(cd %s && GD_OUT_W=%d GD_FPS=%s LD_LIBRARY_PATH=%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec %s) >%s 2>&1 & echo $!",
        shq(GD_HOME), Screen:getWidth(), os.getenv("GD_FPS") or "30", shq(GD_DIR .. "/lib"), shq(exe), shq(GD_LOG))
    local p = io.popen(cmd)
    if not p then return false end
    local pid = p:read("*l")
    p:close()
    Proc.pid = tonumber(pid)
    return Proc.pid ~= nil
end

local function logTail()
    local f = io.open(GD_LOG, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 400))
    local data = f:read("*a") or ""
    f:close()
    return data
end

-- -------------------------------------------------------------- controls ----
-- X11 keysyms understood by geodash/gd_shim.cpp
local K = {
    Left = 0xFF51, Up = 0xFF52, Right = 0xFF53, Down = 0xFF54,
    Enter = 0xFF0D, Esc = 0xFF1B, Space = 0x20,
}
local function ch(c) return c:byte() end

-- Rows of buttons; every row is split evenly, "weight" makes a row taller.
-- kind: nil = hold while touched, "close" = leaves the game.
local LAYOUT = {
    { weight = 2, { "JUMP", K.Space } },
    { { "Esc", K.Esc }, { "Enter", K.Enter }, { "↑", K.Up }, { "↓", K.Down } },
    { { "Restart", ch("r") }, { "Pause", ch("p") }, { "Quit", nil, "close" } },
}

-- -------------------------------------------------------------- the view ----
local GDView = InputContainer:extend{
    name = "GDView",
    covers_fullscreen = true,
}

function GDView:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.held = {}        -- button -> true while its key is down
    self.by_slot = {}     -- touch slot -> button
    self.last_touch = {}  -- button -> os.clock() of last "touch"
    self.status_widget = TextWidget:new{
        text = _("Starting Geometry Rush…"),
        face = Font:getFace("cfont", 22),
        max_width = sw - 40,
    }
    self.label_face = Font:getFace("cfont", 22)
    self.ges_events = {
        TouchPanel = { GestureRange:new{ ges = "touch", range = self.dimen } },
        ReleasePanel = { GestureRange:new{ ges = "release", range = self.dimen } },
        TapPanel = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        -- page-turn buttons: any of them = jump
        self.key_events = {
            PageFire = { { "RPgFwd" }, { "LPgFwd" }, event = "PageFire" },
            PageUse = { { "RPgBack" }, { "LPgBack" }, event = "PageUse" },
        }
    end
    self:layoutPanel()
    self:launch()
end

-- Computes the rectangle of every button below the game picture.
function GDView:layoutPanel(game_h)
    local sw, sh = self.dimen.w, self.dimen.h
    self.game_h = game_h or 0
    self.buttons = {}
    local top = self.game_h
    local margin = Screen:scaleBySize(6)
    local avail = sh - top - margin
    if avail < 100 then return end
    local total = 0
    for _, row in ipairs(LAYOUT) do total = total + (row.weight or 1) end
    local unit = math.min(math.floor(avail / total), Screen:scaleBySize(110))
    local y = top + margin
    for _, row in ipairs(LAYOUT) do
        local row_h = unit * (row.weight or 1)
        local cell_w = math.floor((sw - margin * (#row + 1)) / #row)
        for i, def in ipairs(row) do
            local label = def[1]
            self.buttons[#self.buttons + 1] = {
                label = label, key = def[2], kind = def[3],
                rect = Geom:new{ x = margin + (i - 1) * (cell_w + margin), y = y, w = cell_w, h = row_h - margin },
                text = TextWidget:new{ text = label, face = self.label_face, max_width = cell_w - 8 },
            }
        end
        y = y + row_h
    end
end

function GDView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self.rfb then
        bb:blitFrom(self.rfb.bb, x + self.game_x, y, 0, 0,
            math.min(self.dimen.w, self.rfb.w), self.rfb.h)
        for _, b in ipairs(self.buttons) do
            local r = b.rect
            local active = self.held[b]
            bb:paintRect(x + r.x, y + r.y, r.w, r.h, Blitbuffer.COLOR_BLACK)
            bb:paintRect(x + r.x + 2, y + r.y + 2, r.w - 4, r.h - 4,
                active and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_WHITE)
            local ts = b.text:getSize()
            b.text:paintTo(bb, x + r.x + math.floor((r.w - ts.w) / 2), y + r.y + math.floor((r.h - ts.h) / 2))
        end
    else
        self.status_widget:paintTo(bb, x + 20, y + 20)
    end
end

function GDView:launch()
    if self.rfb then self.rfb:close(); self.rfb = nil end
    if not Proc.start() then
        self:fail(_("Could not start Geometry Rush."))
        return
    end
    self.connect_deadline = os.time() + CONNECT_TIMEOUT
    self.connect_cb = function() self:tryConnect() end
    UIManager:scheduleIn(0.5, self.connect_cb)
    UIManager:setDirty(self, "ui")
end

function GDView:tryConnect()
    if self.closed then return end
    local rfb = RFB.connect(VNC_HOST, VNC_PORT)
    if rfb then
        self.rfb = rfb
        self.game_x = math.max(0, math.floor((self.dimen.w - rfb.w) / 2))
        self:layoutPanel(rfb.h)
        pcall(rfb.requestUpdate, rfb, false)
        self.poll_cb = function() self:pollRfb() end
        UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb)
        UIManager:setDirty(self, "full")
        return
    end
    if os.time() > self.connect_deadline then
        self:fail(_("Geometry Rush did not start.") .. "\n" .. logTail())
        return
    end
    UIManager:scheduleIn(0.4, self.connect_cb)
end

function GDView:pollRfb()
    if self.closed or not self.rfb then return end
    local ok, res = pcall(self.rfb.poll, self.rfb)
    if not ok then
        -- the game quit or crashed.
        logger.warn("GeometryRush: " .. tostring(res))
        self:fail(_("Geometry Rush exited.") .. "\n" .. logTail())
        return
    end
    if res then
        pcall(self.rfb.requestUpdate, self.rfb, true)
        local w, h = res[3] - res[1], res[4] - res[2]
        if w > 0 and h > 0 then
            UIManager:setDirty(self, REFRESH_MODE, Geom:new{ x = self.game_x + res[1], y = res[2], w = w, h = h })
        end
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb)
end

function GDView:fail(message)
    if self.closed then return end
    UIManager:close(self, "full")
    UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 6 })
end

function GDView:sendKey(key, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.key, self.rfb, key, down)
    if not ok then self:fail(tostring(err)) end
end

-- ---------------------------------------------------------------- touch ----
function GDView:buttonAt(pos)
    if not self.rfb then return nil end
    for _, b in ipairs(self.buttons) do
        if b.rect:contains(pos) then return b end
    end
end

function GDView:press(b)
    if b.kind == "close" then
        UIManager:close(self, "full")
        return
    end
    if b.kind == "latch" then
        self.held[b] = not self.held[b] or nil
        self:sendKey(b.key, self.held[b] and true or false)
        UIManager:setDirty(self, "ui", Geom:new{ x = b.rect.x, y = b.rect.y, w = b.rect.w, h = b.rect.h })
        return
    end
    if self.held[b] then return end
    self.held[b] = true
    self:sendKey(b.key, true)
    -- safety net in case the "release" event never arrives
    b.timeout_cb = function() self:release(b) end
    UIManager:scheduleIn(2.5, b.timeout_cb)
end

function GDView:release(b)
    if b.kind == "latch" or b.kind == "close" or not self.held[b] then return end
    self.held[b] = nil
    if b.timeout_cb then UIManager:unschedule(b.timeout_cb); b.timeout_cb = nil end
    self:sendKey(b.key, false)
end

function GDView:pulse(b, seconds)
    self:press(b)
    UIManager:scheduleIn(seconds or 0.15, function() self:release(b) end)
end

-- Position inside the game picture (picture coordinates) or nil.
function GDView:gamePos(pos)
    if not self.rfb or not pos or pos.y >= self.rfb.h then return nil end
    local x = pos.x - self.game_x
    if x < 0 or x >= self.rfb.w then return nil end
    return x, pos.y
end

function GDView:pointer(x, y, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.pointer, self.rfb, x, y, down and 1 or 0)
    if not ok then self:fail(tostring(err)) end
end

function GDView:onTouchPanel(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    if gx then
        self.ptr_slot = self.ptr_slot or {}
        self.ptr_slot[ges.slot or 0] = true
        self.last_game_touch = os.clock()
        self:pointer(gx, gy, true)
        return true
    end
    local b = self:buttonAt(ges.pos)
    if not b then return true end
    self.last_touch[b] = os.clock()
    self.by_slot[ges.slot or 0] = b
    self:press(b)
    return true
end

function GDView:onReleasePanel(_arg, ges)
    local slot = ges.slot or 0
    if self.ptr_slot and self.ptr_slot[slot] then
        self.ptr_slot[slot] = nil
        local gx, gy = self:gamePos(ges.pos)
        self:pointer(gx or 0, gy or 0, false)
        return true
    end
    local b = self.by_slot[slot]
    self.by_slot[ges.slot or 0] = nil
    if not b or not self.held[b] then b = ges.pos and self:buttonAt(ges.pos) end
    if b then self:release(b) end
    return true
end

-- Fallback for devices/KOReader versions that do not deliver touch/release:
-- a plain tap becomes a short key press.
function GDView:onTapPanel(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    if gx then
        if os.clock() - (self.last_game_touch or -10) > 1.0 then
            self:pointer(gx, gy, true)
            UIManager:scheduleIn(0.2, function() self:pointer(gx, gy, false) end)
        end
        return true
    end
    local b = self:buttonAt(ges.pos)
    if not b or b.kind == "latch" or b.kind == "close" then return true end
    if os.clock() - (self.last_touch[b] or -10) > 1.0 then self:pulse(b, 0.2) end
    return true
end

function GDView:pulseKey(key, seconds)
    self:sendKey(key, true)
    UIManager:scheduleIn(seconds or 0.15, function() self:sendKey(key, false) end)
end

function GDView:onPageFire() self:pulseKey(K.Space); return true end
function GDView:onPageUse() self:pulseKey(K.Space); return true end

function GDView:onCloseWidget()
    self.closed = true
    if self.connect_cb then UIManager:unschedule(self.connect_cb) end
    if self.poll_cb then UIManager:unschedule(self.poll_cb) end
    if self.rfb then self.rfb:close(); self.rfb = nil end
    Proc.stop()
    UIManager:setDirty(nil, "full")
end

-- ------------------------------------------------------------ public API ----
local M = {}

function M.available()
    return Proc.available()
end

function M.open()
    local ok, err = Proc.available()
    if not ok then
        UIManager:show(InfoMessage:new{ text = err })
        return false
    end
    UIManager:show(GDView:new{})
    return true
end

M._test = { RFB = RFB, shq = shq, LAYOUT = LAYOUT }

return M
