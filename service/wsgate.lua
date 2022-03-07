local skynet = require "skynet"
local gateserver = require "snax.wsgateserver"
local netpack = require "websocketnetpack"

local watchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }
local forwarding = {}	-- agent -> connection

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

function handler.open(source, conf)
	watchdog = conf.watchdog or source
end

function handler.message(fd, msg, sz)
	-- recv a package, forward it
	local c = connection[fd]
	local agent = c.agent
	print("agent",agent,fd,inspect(msg),inspect(sz))
	if agent then
		skynet.redirect(agent, c.client, "client", fd, msg, sz)
	else
		skynet.send(watchdog or "watchdog", "lua", "socket", "data", fd, netpack.tostring(msg, sz))
		-- print(watchdog, c.client or 0, "client", fd, msg, sz)
		-- skynet.redirect(watchdog, c.client or 0, "client", fd, msg, sz)
	end
end

-- 发送给 watchdog
function handler.connect(fd, addr)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	skynet.send(watchdog, "lua", "socket", "open", fd, addr, "websocket")
	--gateserver.openclient(fd)

	print(inspect(connection))
end

local function unforward(c)
	if c.agent then
		forwarding[c.agent] = nil
		c.agent = nil
		c.client = nil
	end
end

local function close_fd(fd)
	local c = connection[fd]
	if c then
		print("wsgate close_fd", fd)
		unforward(c)
		connection[fd] = nil
		gateserver.closeclient(fd)
		return true
	end
end

function handler.disconnect(fd)
	print("wsgate disconnect", fd)
	if close_fd(fd) then
		skynet.send(watchdog, "lua", "socket", "close", fd)
		gateserver.closeclient(fd)
	end
end


function handler.error(fd, msg)
	if close_fd(fd) then
		skynet.send(watchdog, "lua", "socket", "error", fd)
	end
end

function handler.warning(fd, size)
	skynet.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

function CMD.watchdog(source, _watchdog)
	print(source, _watchdog)
	watchdog = _watchdog
end

-- 这里的 agent 进房前是 watchdog 进房后是 房间地址
function CMD.forward(source, fd, client, address)
	print("wsgate forward",source, fd, client, address)
	skynet.trace()
	local c = assert(connection[fd])
	unforward(c)
	c.client = client or 0
	c.agent = address or source
	forwarding[c.agent] = c
	gateserver.openclient(fd)
end

function CMD.accept(source, fd)
	local c = assert(connection[fd])
	unforward(c)
	gateserver.openclient(fd)
end

function CMD.kick(source, fd)
	close_fd(fd)
end
--逻辑 自己调自己
function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
