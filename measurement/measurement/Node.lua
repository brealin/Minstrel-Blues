require ('rpc')
require ('spawn_pipe')
require ('parentpid')
local unistd = require ('posix.unistd')
require ('NetIF')
require ('misc')
require ('parsers/iw_link')
require ('parsers/ifconfig')
require ('parsers/dhcp_lease')

local iperf_bin = "iperf"
local lease_fname = "/tmp/dhcp.leases"

-- TODO: 
-- - STA connect to AP
-- - split Node into NodeAP, NodeSTA

Node = { name = nil, wifi = nil, ctrl = nil 
       , iperf_port = nil, tcpdump_proc = nil
       , cpusage_proc = nil
       , log_port = nil
       , regmon_proc = nil
       , rc_stats_procs = nil
       }

function Node:new (o)
    local o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Node:create ( name, wifi, ctrl, iperf_port, log_ip, log_port )
    local o = Node:new({ name = name, wifi = wifi, ctrl = ctrl
                       , iperf_port = iperf_port, log_ip = log_ip, log_port = log_port 
                       , rc_stats_procs = {}
                       })
    return o
end

function Node:__tostring() 
    return self.name .. " :: " 
            .. tostring(self.wifi) .. ", "
            .. tostring(self.ctrl)
end

function Node:run( port )
    -- tatsaechliche IP-Adresse abfragen
    if rpc.mode == "tcpip" then
        self:send_info("Service " .. self.name .. " started")
        self:set_cut()
        rpc.server(port);
    else
        print ( "Err: tcp/ip supported only" )
    end
end

local debugfs = "/sys/kernel/debug/ieee80211"

-- --------------------------
-- wifi
-- --------------------------

-- AP only
function Node:get_ssid( iface )
    self:send_info("send ssid for " .. iface)
    local iwinfo = spawn_pipe("iw", iface, "info")
    local exit_code = iwinfo['proc']:wait()
    if (exit_code == 0) then
        -- TODO: parse response
        local str = iwinfo ['out']:read("*all")
        close_proc_pipes ( iwinfo )
        str = string.gsub ( str, "\t", " " )
        str = string.gsub ( str, "\n", " " )
        local tokens = split ( str, " " )
        for i, token in ipairs( tokens ) do
            if ( token == "ssid") then
                return tokens [ i + 1 ]
            end
        end
    end
    return nil
end

function Node:restart_wifi()
    local wifi = spawn_pipe("wifi")
    local exit_code = wifi['proc']:wait()
    self:send_info("restart wifi")
    return exit_code == 0
end

-- iw phy phy0 interface add wlan0 type monitor
-- ifconfig wlan0 up
-- fixme: command failed: Too many open files in system (-23)
--   root@lede-sta:~# cat /proc/sys/fs/file-max
--   12505
--   root@lede-sta:~# lsof | wc -l
--   643
function Node:add_monitor ( phy )
    local iw_info = spawn_pipe("iw", "dev", self.wifi.mon, "info")
    local exit_code = iw_info['proc']:wait()
    if (exit_code ~= 0) then
        self:send_info("Adding monitor " .. self.wifi.mon .. " to " .. phy)
        local iw_add = spawn_pipe("iw", "phy", phy, "interface", "add", self.wifi.mon, "type", "monitor")
        local exit_code = iw_add['proc']:wait()
        if (exit_code ~= 0) then
            self:send_info("Add monitor failed: " .. exit_code)
        end
    end
    self:send_info("enable monitor " .. self.wifi.mon)
    local ifconfig = spawn_pipe("ifconfig", self.wifi.mon, "up")
    local exit_code = ifconfig['proc']:wait()
end


function Node:wifi_devices ()
    self:send_info("Send phy devices for " .. self.wifi.iface)
    local phys = {}
    for file in lfs.dir( debugfs ) do
        if (file ~= "." and file ~= "..") then
            phys [ #phys + 1 ] = file
        end
    end
    table.sort ( phys )
    self:send_info(" phys: " .. foldr ( string.concat, "" , phys ) )
    return phys
end

function list_stations ( phy, iface )
    local stations = debugfs .. "/" .. phy .. "/netdev:" .. iface .. "/stations/"
    local out = {}
    for _, name in ipairs ( scandir ( stations ) ) do
        if ( name ~= "." and name ~= "..") then
            out [ #out + 1 ] = name
        end
    end
    return out
end

function Node:stations ( phy )
    local list = list_stations ( phy, self.wifi.iface )
    self:send_info("Send stations for " .. self.wifi.iface )
    return list
end

function Node:set_ani ( phy, enabled )
    self:send_info("set ani for " .. phy .. " to " .. tostring ( enabled ) )
    local filename = debugfs .. "/" .. phy .. "/" .. "ath9k" .. "/"  .. "ani"
    local file = io.open ( filename, "w" )
    if ( enabled ) then
        file:write(1)
    else
        file:write(0)
    end
    file:close()
end

function Node:get_mac ( iface )
    self:send_info("send mac for " .. iface )
    local ifconfig_proc = spawn_pipe( "ifconfig", iface )
    ifconfig_proc['proc']:wait()
    local ifconfig = parse_ifconfig ( ifconfig_proc['out']:read("*a") )
    if ( ifconfig == nil or ifconfig.mac == nil ) then return nil end
    self:send_info(" mac for " .. iface .. ": " .. ifconfig.mac )
    return ifconfig.mac
end

function Node:get_addr ( iface )
    self:send_info("send ipv4 addr for " .. iface )
    local ifconfig_proc = spawn_pipe( "ifconfig", iface )
    ifconfig_proc['proc']:wait()
    local ifconfig = parse_ifconfig ( ifconfig_proc['out']:read("*a") )
    if (ifconfig == nil or ifconfig.addr == nil) then 
        self:send_error(" interface " .. iface .. " has no ipv4 addr assigned")
        return nil 
    end
    self:send_info(" addr for " .. iface .. ": " .. ifconfig.addr )
    return ifconfig.addr
end

-- returns addr when host with mac has a dhcp lease else nil
function Node:has_lease ( mac )
    self:send_info("send ipv4 addr for " .. mac .. " from lease" )
    local file = io.open ( lease_fname )
    if ( not isFile ( lease_fname ) ) then return nil end
    local content = file:read("*a")
    for _, line in ipairs ( split ( content, '\n' ) ) do
        local lease = parse_dhcp_lease ( line )
        if ( lease ~= nil and lease.mac == mac ) then
            file:close()
            return lease.addr
        end
    end
    file:close()
    return nil
end

-- returns the ssid when iface is connected
-- otherwise nil is returned
function Node:get_linked_ssid ( iface )
    local iwlink_proc = spawn_pipe( "iw", "dev", iface, "link" )
    iwlink_proc['proc']:wait()
    local iwlink = parse_iwlink ( iwlink_proc['out']:read("*a") )
    if (iwlink == nil) then return nil end
    return iwlink.ssid
end

-- returns the remote iface when iface is connected
-- otherwise nil is returned
function Node:get_linked_iface ( iface )
    local iwlink_proc = spawn_pipe( "iw", "dev", iface, "link" )
    iwlink_proc['proc']:wait()
    local iwlink = parse_iwlink ( iwlink_proc['out']:read("*a") )
    if (iwlink == nil) then return nil end
    return iwlink.iface
end

-- returns the remote mac when iface is connected
-- otherwise nil is returned
function Node:get_linked_mac ( iface )
    local iwlink_proc = spawn_pipe( "iw", "dev", iface, "link" )
    iwlink_proc['proc']:wait()
    local iwlink = parse_iwlink ( iwlink_proc['out']:read("*a") )
    if (iwlink == nil) then return nil end
    return iwlink.mac
end

-- --------------------------
-- rc_stats
-- --------------------------

-- fixme: list_stations differs from time to time, use fixed station list

function Node:start_rc_stats ( phy, stations )
    self:send_info("start collecting rc stats for " .. self.wifi.iface .. ", " .. phy)
    local out = {}
    for _, station in ipairs ( stations ) do
        self:send_info ( " start collecting rc_stats stations: " .. station )
        local file = debugfs .. "/" .. phy .. "/netdev:" .. self.wifi.iface .. "/stations/"
                        .. station .. "/rc_stats_csv"
        local rc_stats = spawn_pipe ( "lua", "bin/fetch_file.lua", "-i", "50000", file )
        if ( rc_stats ['err_msg'] ~= nil ) then
            self:send_error("fetch_file: " .. rc_stats ['err_msg'] )
        end
        self.rc_stats_procs [ station ] = rc_stats
        self:send_info("rc stats for station " .. station .. " started " .. rc_stats['proc']:__tostring())
        out [ #out + 1 ] = rc_stats['proc']:__tostring()
    end
    return out
end

function Node:get_rc_stats ( station )
    if ( station == nil ) then
        self:send_error ( "Cannot send rc_stats because the station argument is nil!" )
        return nil
    end
    self:send_info("send rc-stats for " .. self.wifi.iface ..  ", station " .. station)
    if ( self.rc_stats_procs [ station ] == nil) then return nil end
    local content = self.rc_stats_procs [ station ] [ 'out' ]:read("*a")
    self:send_info ( string.len ( content ) .. " bytes from rc_stats" )
    close_proc_pipes ( self.rc_stats_procs [ station ] )
    return content 
end

function Node:stop_rc_stats ( pid )
    if ( pid == nil ) then 
        self:send_error ( "Cannot kill rc stats because pid is nil!" )
        return nil
    end
    self:send_info("stop collecting rc stats with pid " .. pid)
    return kill ( pid )
end

-- --------------------------
-- regmon stats
-- --------------------------

function Node:start_regmon_stats ( phy )
    local file = debugfs .. "/" .. phy .. "/regmon/register_log"
    if (not isFile(file)) then
        self:send_warning("no regmon-stats for " .. self.wifi.iface .. ", " .. phy)
        self.regmon_proc = nil
        return nil
    end
    self:send_info("start collecting regmon stats for " .. self.wifi.iface .. ", " .. phy)
    local regmon = spawn_pipe( "lua", "bin/fetch_file.lua", "-l", "-i", "50000", file )
    self.regmon_proc = regmon
    return regmon['proc']:__tostring()
end

function Node:get_regmon_stats ()
    self:send_info("send regmon-stats")
    if (self.regmon_proc == nil) then 
        self:send_error("no regmon process running" )
        return nil 
    end
    local content = self.regmon_proc['out']:read("*a")
    self:send_info ( string.len ( content ) .. " bytes from regmon" )
    close_proc_pipes ( self.regmon_proc )
    return content
end

function Node:stop_regmon_stats ( pid )
    self:send_info("stop collecting regmon stats with pid " .. pid)
    return kill ( pid )
end

-- --------------------------
-- cpusage
-- --------------------------

local cpusage_dump_fname = "/tmp/cpusage_dump"
function Node:start_cpusage ()
    self:send_info("start cpusage")
    local cpusage = spawn_pipe( "cpusage_single" )
    self.cpusage_proc = cpusage
    return cpusage['proc']:__tostring()
end

function Node:get_cpusage()
    self:send_info("send cpusage")
    if ( self.cpusage_proc == nil ) then return nil end
    local a = self.cpusage_proc['out']:read("*all")
    self:send_info ( string.len ( a ) .. " bytes from cpusage" )
    close_proc_pipes ( self.cpusage_proc )
    return a
end

function Node:stop_cpusage ( pid )
    self:send_info("stop cpusage with pid " .. pid)
    -- self.cpusage_proc = nil -- needed to read pipe
    return kill ( pid )
end

-- --------------------------
-- tcpdump
-- --------------------------

-- TODO: lock
-- -U packet-buffered output instead of line buffered (-l)
-- tcpdump -l | tee file
-- tcpdump -i mon0 -s 150 -U
-- tcpdump: mon0: SIOCETHTOOL(ETHTOOL_GET_TS_INFO) ioctl failed: No such device
function Node:start_tcpdump ( fname )
    self:send_info("start tcpdump for " .. self.wifi.mon)
    local tcpdump = spawn_pipe( "tcpdump", "-i", self.wifi.mon, "-s", "150", "-U", "-w", fname)
--    local tcpdump, _ = spawn_pipe2( { "tcpdump", "-i", self.wifi.mon, "-s", "150", "-U", "-w", "-" },
--                                 { "tee", "-a", fname } )
    self.tcpdump_proc = tcpdump
--    repeat
        local line = tcpdump['err']:read('*line')
        if line then self:send_info(line) end
--    until line == nil
    return tcpdump['proc']:__tostring()
end


function Node:get_tcpdump_online()
    self:send_info("send tcpdump")
--    repeat
--        local l = self.tcpdump_proc['out']:read("*line")
--        if (c ~= nil) then print (l) end
--    until (l == nil)

    if not self.tcpdump_proc then return nil end
    local l = self.tcpdump_proc['out']:read("*line")
    close_proc_pipes ( self.tcpdump_proc )
--    if (l ~= nil) then print ("tcpdump: " .. l) end
    return l
end

function Node:get_tcpdump_offline ( fname )
    self:send_info("send tcpdump offline for file " .. fname)
    local file = io.open ( fname, "rb" )
    if ( file == nil ) then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

-- TODO: unlock
function Node:stop_tcpdump ( pid )
    self:send_info("stop tcpdump with pid " .. pid)
--    local line = self.tcpdump_proc['err']:read('*line')
--    if line then self:send_info(line) end
--    self.tcpdump_proc = nil
    return kill ( pid )
end

-- --------------------------
-- iperf
-- --------------------------

-- TODO: lock
-- fixme: rpc function name to long
function Node:start_tcp_iperf_s ()
    self:send_info("start TCP iperf server at port " .. self.iperf_port)
    local iperf = spawn_pipe(iperf_bin, "-s", "-p", self.iperf_port)
    return iperf['proc']:__tostring()
end

-- TODO: lock
-- iperf -s -u -p 12000
-- fixme: rpc function name to long
function Node:start_udp_iperf_s ()
    self:send_info("start UDP iperf server at port " .. self.iperf_port)
    local iperf = spawn_pipe(iperf_bin, "-s", "-u", "-p", self.iperf_port)
    if ( iperf['err_msg'] ~= nil ) then
        self:send_error(iperf_bin .. "-s" .. "-u" .. "-p" .. self.iperf_port)
        self:send_error("run udp iperf failed: " .. iperf['err_msg'])
        local msg = iperf['err']:read("*all")
        self:send_error(msg)
        return nil
    else
        for i=1,5 do
            local msg = iperf['out']:read("*l")
            self:send_info(msg)
        end
    end
    return iperf['proc']:__tostring()
end

-- TODO: lock / unlock
-- note: don't forget to wait for pid
function Node:run_tcp_iperf ( tcpdata )
    self:send_info("run TCP iperf at port " .. self.iperf_port 
                                .. " on iface " .. self.wifi.iface 
                                .. " with tcpdata " .. tcpdata)
    local iperf = spawn_pipe(iperf_bin, "-c", self.wifi.iface, "-p", self.iperf_port, "-n", tcpdata)
    return iperf['proc']:__tostring()
end

-- TODO: lock / unlock
-- iperf -u -c 192.168.1.1 -p 12000 -l 1500B -b 600000 -t 240
function Node:run_udp_iperf ( size, rate, interval )
    self:send_info("run UDP iperf at port " .. self.iperf_port 
                                .. " on iface " .. self.wifi.addr 
                                .. " with size, rate and interval " .. size .. ", " .. rate .. ", " .. interval)
    local bitspersec = size * 8 * rate
    local iperf = spawn_pipe ( iperf_bin, "-u", "-c", self.wifi.addr, "-p", self.iperf_port, "-l", size .. "B", "-b", bitspersec, "-t", interval)
    if ( iperf['err_msg'] ~= nil ) then
        self:send_error ( iperf_bin .. " -u " .. " -c " .. self.wifi.addr .. " -p " .. self.iperf_port .. " -l " .. size .. "B " .. " -b " .. bitspersec .. " -t " .. interval)
        self:send_error ( "run udp iperf failed: " .. iperf ['err_msg'] )
        return nil
    end
    local exit_code = iperf['proc']:wait()
    if (exit_code ~= 0) then
        self:send_error("run udp iperf quit with exit code: " .. exit_code)
        local msg = iperf['err']:read("*all")
        self:send_error(msg)
    else 
        repeat
            line = iperf['out']:read("*l")
            if line ~= nil then self:send_info ( line ) end
        until line == nil
    end
    return iperf['proc']:__tostring()
end

-- TODO: unlock
function Node:stop_iperf_server ( pid )
    self:send_info("stop iperf server with pid " .. pid)
    return kill ( pid )
end

-- -------------------------
-- posix
-- -------------------------

function Node:get_pid()
    local lua_pid = unistd.getpid()
    return lua_pid
end

-- kill child process of lua by pid
-- if process with pid is not a child of lua
-- then return nil
-- otherwise the exit code of kill is returned
function kill ( pid, signal )
    local lua_pid = unistd.getpid()
    if (parent_pid ( pid ) == lua_pid) then
        local kill
        if (signal ~= nil) then
            kill = spawn_pipe("kill","-"..signal,pid)
        else
            kill = spawn_pipe("kill", pid)
        end
        return kill['proc']:wait()
    else 
        self:send_warning("try to kill pid " .. pid)
        return nil
    end
    -- TODO: creates zombies
end

-- -------------------------
-- Logging
-- -------------------------

function Node:connect_logger ()
    function connect ()
        local l, e = rpc.connect (self.log_ip, self.log_port)
        return l, e
    end
    local status, logger, err = pcall ( connect )
    -- TODO: print this message a single time only
    if (status == false) then
        print ( "Err: Connection to Logger failed" )
        print ("Err: no logger at address: " .. self.log_ip .. " on port: " .. self.log_port)
        return nil
    else
        return logger
    end
end

function Node:disconnect_logger ( logger )
    if (logger ~= nil) then
        rpc.close (logger)
    end
end

function Node:set_cut ()
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.set_cut ()    
    end
    self:disconnect_logger ( logger )
end

function Node:send_error( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_error( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end

function Node:send_info( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_info( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end

function Node:send_warning( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_warning( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end