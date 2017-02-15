
require ('NetIF')
require ('spawn_pipe')
require ('parsers/ex_process')
require ('parsers/dig')
require ('parsers/ifconfig')
require ('AccessPointRef')
require ('StationRef')
local unistd = require ('posix.unistd')
require ('net')

ControlNode = { name = name
              , ctrl = ctrl
              , port = port
              , ap_refs = nil     -- list of access point nodes
              , sta_refs = nil    -- list of station nodes
              , stats = nil   -- maps node name to statistics
              , pids = nil    -- maps node name to process id of lua node
              , logger_proc = nil
              , log_ip = nil
              , log_port = nil
              }


function ControlNode:new (o)
    local o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function ControlNode:create ( name, ctrl_if, port, log_ip, log_port )
    local o = ControlNode:new ( { name = name
                                , ctrl_if = ctrl_if
                                , ap_refs = {}
                                , sta_refs = {}
                                , stats = {}
                                , pids = {}
                                , port = port
                                , log_ip = log_ip
                                , log_port = log_port
                                } )
    return o
end


function ControlNode:__tostring()
    local out = "if: " .. ( self.ctrl_if or "none" ) .. "\n"
    out = out .. "port: " .. ( self.port or "none" ) .. "\n"
    out = out .. "log ip: " .. ( self.log_ip or "none" ) .."\n"
    out = out .. "log port: " .. ( self.log_port or "none" ) .. "\n"
    for i, ap_ref in ipairs ( self.ap_refs ) do
        out = out .. '\n'
        out = out .. ap_ref:__tostring()
    end
    out = out .. '\n'
    for i, sta_ref in ipairs ( self.sta_refs ) do
        out = out .. '\n'
        out = out .. sta_ref:__tostring()
    end
    return out
end

function ControlNode:run( port )
    self.port = port
    if rpc.mode == "tcpip" then
        self:send_info ( "Service Control started" )
        self:set_cut ()
        rpc.server ( port )
    else
        self:send_error ( "Err: tcp/ip supported only" )
    end
end


function ControlNode:get_ctrl_addr ()
    return get_addr ( self.ctrl_if )
end

function ControlNode:add_ap_ref ( ap_ref )
    self.ap_refs [ #self.ap_refs + 1 ] = ap_ref
end

function ControlNode:add_sta_ref ( sta_ref )
    self.sta_refs [ #self.sta_refs + 1 ] = sta_ref
end

function ControlNode:add_ap ( name, ctrl_if, ctrl_port )
    self:send_info ( " add access point " .. name )
    local ctrl = NetIF:create ( "ctrl", ctrl_if )
    local ref = AccessPointRef:create ( name, ctrl, ctrl_port )
    self.ap_refs [ #self.ap_refs + 1 ] = ref 
end

function ControlNode:add_sta ( name, ctrl_if, ctrl_port )
    self:send_info ( " add station " .. name )
    local ctrl = NetIF:create ( "ctrl", ctrl_if )
    local ref = StationRef:create ( name, ctrl, ctrl_port )
    self.sta_refs [ #self.sta_refs + 1 ] = ref 
end

function ControlNode:nodes() 
    self:send_info ( " query nodes" )
    if ( self.node_refs == nil ) then
        self.node_refs = {}
        for _,v in ipairs(self.sta_refs) do self.node_refs [ #self.node_refs + 1 ] = v end
        for _,v in ipairs(self.ap_refs) do self.node_refs [ #self.node_refs + 1 ] = v end
    end
    return self.node_refs
end

function ControlNode:find_node( name ) 
    for _, node in ipairs ( self:nodes() ) do 
        if node.name == name then return node end 
    end
    return nil
end

function ControlNode:reachable ()
    function reachable_ ( ip ) 
        local ping = spawn_pipe("ping", "-c1", ip)
        local exitcode = ping['proc']:wait()
        close_proc_pipes ( ping )
        return exitcode == 0
    end

    local reached = {}
    for _, node in ipairs ( self:nodes() ) do
        local addr = lookup ( node.name )
        if ( addr == nil ) then
            break
        end
        node.ctrl.addr = addr
        if reachable_ ( addr ) then
            reached [ node.name ] = true
        else
            reached [ node.name ] = false
        end
    end
    return reached
end

function ControlNode:start( log_addr, log_port, log_file )

    function start_logger ( addr, port, file )
        local logger = spawn_pipe ( "lua", "bin/runLogger.lua", file, "--port", port )
        if ( logger ['err_msg'] ~= nil ) then
            self:send_warning("Logger not started" .. logger ['err_msg'] )
        end
        close_proc_pipes ( logger )
        local str = logger['proc']:__tostring()
        return parse_process ( str ) 
    end

    function start_logger_remote ( addr, port, file )
        local remote_cmd = "lua bin/runLogger.lua " .. file
                    .. " --port " .. port 
 
        if ( addr ~= nil ) then
            remote_cmd = remote_cmd .. " --log_ip " .. addr 
        end
        print ( remote_cmd )
        local ssh = spawn_pipe("ssh", "root@" .. addr, remote_cmd)
        close_proc_pipes ( ssh )
    end

    function start_node ( node, log_addr )

        local remote_cmd = "lua runNode.lua"
                    .. " --name " .. node.name 

        if ( log_addr ~= nil and log_port ~= nil and log_file ~= nil ) then
            remote_cmd = remote_cmd .. " --log_ip " .. log_addr 
        end
        print ( remote_cmd )
        local ssh = spawn_pipe("ssh", "root@" .. node.ctrl.addr, remote_cmd)
        close_proc_pipes ( ssh )
--[[    local exit_code = ssh['proc']:wait()
        if (exit_code == 0) then
            print (node.name .. ": node started" )
        else
            print (node.name .. ": node not started, exit code: " .. exit_code)
            print ( ssh['err']:read("*all") )
            os.exit(1)
        end --]]
    end

    if ( log_addr ~= nil and log_port ~= nil and log_file ~= nil ) then
        self.pids['logger'] = start_logger ( log_addr, log_port, log_file ) ['pid']
        if ( self.pids['logger'] == nil ) then
            print ("Logger not started.")
            return false
        end
    end

    for _, node in ipairs ( self:nodes() ) do
        start_node( node, log_addr )
    end
    return true
end

function ControlNode:connect ( ctrl_port )
    if rpc.mode ~= "tcpip" then
        print ( "Err: rpc mode tcp/ip is supported only" )
        return false
    end

    for _, node_ref in ipairs ( self:nodes() ) do
        node_ref:connect ( ctrl_port )
        if ( node_ref.rpc == nil ) then
            print ("Connection to " .. node_ref.name .. " failed")
            return false
        else 
            print ("Connected to " .. node_ref.name)
        end
    end

    -- query lua pid before closing rpc connection
    -- maybe to kill nodes later
    for _, node_ref in ipairs ( self:nodes() ) do 
        self.pids[ node_ref.name ] = node_ref.rpc.get_pid()
    end

    return true
end

function ControlNode:disconnect()
    for _, node_ref in ipairs ( self:nodes() ) do 
        rpc.close ( node_ref.rpc )
    end
end

-- runs experiment 'exp' for all nodes 'ap_refs'
-- in parallel
-- see run_experiment in Experiment.lua for
-- a sequential variant
function ControlNode:run_experiments ( exp, ap_refs )

    local ret = true

    for _, ap_ref in ipairs ( ap_refs ) do
        exp:prepare_measurement ( ap_ref )
    end

    local keys = {}
    for i, ap_ref in ipairs ( ap_refs ) do
        keys[i] = exp:keys ( ap_ref )
    end

    for _, key in ipairs ( keys[1] ) do -- fixme: smallest set of keys

        for _, ap_ref in ipairs ( ap_refs ) do
            exp:settle_measurement ( ap_ref, key )
        end

        -- -------------------------------------------------------
        for _, ap_ref in ipairs ( ap_refs ) do
            exp:start_measurement (ap_ref, key )
        end

        -- -------------------------------------------------------
        -- Experiment
        -- -------------------------------------------------------
            
        for _, ap_ref in ipairs ( ap_refs ) do
            exp:start_experiment ( ap_ref )
        end
    
        for _, ap_ref in ipairs ( ap_refs ) do
            exp:wait_experiment ( ap_ref )
        end

        -- -------------------------------------------------------

        for _, ap_ref in ipairs ( ap_refs ) do
            exp:stop_measurement (ap_ref, key )
        end

        for _, ap_ref in ipairs ( ap_refs ) do
            exp:unsettle_measurement ( ap_ref, key )
        end

    end

    for _, ap_ref in ipairs ( ap_refs ) do
        self.stats [ ap_ref.name ] = ap_ref.stats
        for _, sta_ref in ipairs ( ap_ref.refs ) do
            self.stats [ sta_ref.name ] = sta_ref.stats
        end
    end

    return ret

end

-- runs experiment 'exp' for node 'ap_ref'
-- sequentially
-- see run_experiment in Experiment.lua
function ControlNode:run_experiment ( exp, ap_ref )

    local status
    local err
    status, err = pcall ( function () return exp ( ap_ref ) end )

    if ( status == false ) then 
        print ( "Error: experiment failed:\n" .. err )
        return false 
    end

    self.stats [ ap_ref.name ] = ap_ref.stats
    for _, sta_ref in ipairs ( ap_ref.refs ) do
        self.stats [ sta_ref.name ] = sta_ref.stats
    end
    return true

end

function ControlNode:stop()

    function stop_logger ( pid )
        kill = spawn_pipe("kill", pid)
        close_proc_pipes ( kill )
    end

    for i, node_ref in ipairs ( self:nodes() ) do
        local ssh = spawn_pipe("ssh", "root@" .. node_ref.ctrl.addr, "kill " .. self.pids [ node_ref.name ] )
        local exit_code = ssh['proc']:wait()
        close_proc_pipes ( ssh )
    end
    stop_logger ( self.pids['logger'] )
end

-- -------------------------
-- posix
-- -------------------------

function ControlNode:get_pid()
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
        local exit_code = kill['proc']:wait()
        close_proc_pipes ( kill )
        return exit_code
    else 
        self:send_warning("try to kill pid " .. pid)
        return nil
    end
    -- TODO: creates zombies
end


-- -------------------------
-- Logging
-- -------------------------

function ControlNode:connect_logger ()
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

function ControlNode:get_logger_addr ()
    local logger = self:connect_logger()
    local addr = logger.get_addr() 
    self:disconnect_logger ( logger )
    return addr
end

function ControlNode:disconnect_logger ( logger )
    if (logger ~= nil) then
        rpc.close (logger)
    end
end

function ControlNode:set_cut ()
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.set_cut ()    
    end
    self:disconnect_logger ( logger )
end

function ControlNode:send_error( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_error( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end

function ControlNode:send_info( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_info( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end

function ControlNode:send_warning( msg )
    local logger = self:connect_logger()
    if (logger ~= nil) then
        logger.send_warning( self.name, msg )    
    end
    self:disconnect_logger ( logger )
end