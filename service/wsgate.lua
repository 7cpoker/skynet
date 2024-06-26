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
	if agent then
		skynet.redirect(agent, c.client, "client", fd, msg, sz)
	else
		skynet.send(watchdog or "watchdog", "lua", "socket", "data", fd, netpack.tostring(msg, sz))
	end
end

function handler.connect(fd, addr)
	local c = {
		fd = fd,
		ip = addr,
	}
	connection[fd] = c
	skynet.send(watchdog, "lua", "socket", "open", fd, addr, "websocket")
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
		unforward(c)
		connection[fd] = nil
		gateserver.closeclient(fd)
		return true
	end
end

function handler.disconnect(fd)
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
	watchdog = _watchdog
end

function CMD.reforward(source, fd, client, address)
	local c = connection[fd]
	if c then
		unforward(c)
		c.client = client or 0
		c.agent = address or source
		forwarding[c.agent] = c
	end
end

function CMD.forward(source, fd, client, address)
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

function handler.command(cmd, source, ...)
	local f = assert(CMD[cmd])
	return f(source, ...)
end

gateserver.start(handler)
