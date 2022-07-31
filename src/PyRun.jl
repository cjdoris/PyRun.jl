module PyRun

import Base64, CondaPkg, JSON3, Sockets

export PyProcess, pyrun, PyRef

const SERVER_PY = joinpath(@__DIR__, "server.py")

mutable struct PyProcess
    proc::Base.Process
    sock::Sockets.TCPSocket
    send_lock::ReentrantLock
    recv_task::Task
    channel_counter::Int
    channels::Dict{String,Channel{Any}}
    channels_lock::ReentrantLock
    stdout_task::Task
    PyProcess(args...) = finalizer(_finalize_pyprocess, new(args...))
end

mutable struct PyRef
    proc::PyProcess
    ref::String
    global _pyref(proc::PyProcess, ref::String) = finalizer(_finalize_pyref, new(proc, ref))
end

Base.show(io::IO, p::PyProcess) = print(io, "PyProcess()")

function _finalize_pyprocess(p::PyProcess)
    isopen(p) && close(p)
    return
end

Base.isopen(p) = isopen(p.proc) && isopen(p.sock)
Base.close(p) = (send(p, (; tag="close")); close(p.sock); close(p.proc); kill(p.proc); nothing)

function PyProcess()
    proc = CondaPkg.withenv() do 
        open(`python -X utf8 $SERVER_PY`; read=true, write=true)
    end
    msg = JSON3.read(readline(proc))
    status = msg[:status]::String
    if status == "ERROR"
        error("Python server did not start: $(msg[:msg]::String)")
    end
    @assert status == "READY"
    addr = msg[:addr]::String
    port = msg[:port]::Int
    sock = Sockets.connect(addr, port)
    send_lock = ReentrantLock()
    channels = Dict{String,Channel{Any}}()
    channels_lock = ReentrantLock()
    recv_task = @async recv_loop($sock, $channels, $channels_lock)
    stdout_task = @async write($stdout, $proc)
    return PyProcess(proc, sock, send_lock, recv_task, 0, channels, channels_lock, stdout_task)
end

const DEFAULT_PROCESS = Ref{Union{PyProcess,Nothing}}(nothing)
function default_process()
    proc = DEFAULT_PROCESS[]
    if proc === nothing
        proc = PyProcess()
        DEFAULT_PROCESS[] = proc
    end
    return proc::PyProcess
end

function send(p::PyProcess, x)
    @lock p.send_lock begin
        println(p.sock, JSON3.write(x))
        flush(p.sock)
    end
    return
end

function recv_loop(sock, channels, channels_lock)
    for line in eachline(sock)
        msg = JSON3.read(line)
        id = msg[:id]::String
        channel = @lock channels_lock get(channels, id, nothing)
        channel === nothing && continue
        put!(channel, msg)
    end
end

function new_channel(p::PyProcess)
    @lock p.channels_lock begin
        n = p.channel_counter += 1
        id = string(n)
        ch = Channel()
        p.channels[id] = ch
        return id, ch
    end
end

function del_channel(p::PyProcess, chid::String)
    @lock p.channels_lock begin
        delete!(p.channels, chid)
    end
end

function pyrun(p::PyProcess, code::AbstractString; scope::AbstractString="@main", locals=NamedTuple())
    id, ch = new_channel(p)
    GC.@preserve locals try
        send(p, (; tag="run", id, code, scope, locals=format_locals(p, locals)))
        for msg in ch
            tag = msg[:tag]::String
            if tag == "result"
                return parse_result(p, msg[:result])
            elseif tag == "error"
                error("Python error: $(msg[:type]::String): $(msg[:str]::String)")
            else
                @assert false
            end
        end
    finally
        del_channel(p, id)
    end
end

pyrun(code::AbstractString; kw...) = pyrun(default_process(), code; kw...)

format_locals(p::PyProcess, ::Nothing) = nothing
format_locals(p::PyProcess, x::NamedTuple) = format_locals(p, pairs(x))
format_locals(p::PyProcess, x) = Dict(k => format_local(p, v) for (k, v) in x)

function format_local(p::PyProcess, x::PyRef)
    getfield(x, :proc) === p || error("different process")
    return (; t="ref", v=getfield(x, :ref))
end

format_local(p::PyProcess, x::Nothing) = x
format_local(p::PyProcess, x::Missing) = nothing
format_local(p::PyProcess, x::Bool) = x
format_local(p::PyProcess, x::AbstractString) = convert(String, x)
format_local(p::PyProcess, x::Symbol) = String(x)
format_local(p::PyProcess, x::Tuple) = (; t="tuple", v=map(x->format_local(p, x), x))
format_local(p::PyProcess, x::Pair) = (; t="pair", v=(format_local(p, x.first), format_local(p, x.second)))
format_local(p::PyProcess, x::AbstractVector) = (; t="list", v=map(x->format_local(p, x), x))
format_local(p::PyProcess, x::Integer) = (; t="int", v=string(convert(BigInt, x)))
format_local(p::PyProcess, x::Union{Float64,Float32,Float16}) = (; t="float", v=string(x))
format_local(p::PyProcess, x::AbstractDict) = (; t="dict", v=[(format_local(p, k), format_local(p, v)) for (k, v) in x])
format_local(p::PyProcess, x::NamedTuple) = (; t="dict", v=[(format_local(p, k), format_local(p, v)) for (k, v) in pairs(x)])

parse_result(p::PyProcess, res::Union{Nothing,Bool,String,Int}) = res

function _parse_int(v)
    x = tryparse(Int, v)
    return x === nothing ? parse(BigInt, v) : x
end

function parse_result(p::PyProcess, res::JSON3.Object)
    t = res[:t]::String
    v = res[:v]
    if t == "int"
        return _parse_int(v::String)
    elseif t == "float"
        return parse(Float64, v::String)
    elseif t == "rational"
        return _parse_int(v[1]::String) // _parse_int(v[2]::String)
    elseif t == "ref"
        return _pyref(p, v::String)
    elseif t == "list"
        return [parse_result(p, x) for x in v::JSON3.Array]
    elseif t == "tuple"
        return Tuple(parse_result(p, x) for x in v::JSON3.Array)
    elseif t == "set"
        return Set(parse_result(p, x) for x in v::JSON3.Array)
    elseif t == "dict"
        return Dict(parse_result(p, k) => parse_result(p, v) for (k, v) in v::JSON3.Array)
    elseif t == "bytes"
        return Base64.base64decode(v::String)
    else
        return res
    end
end

PyRef(x::PyRef) = x
PyRef(x) = pyrun("jl.ret(x, jl.Ref())", locals=(; x))::PyRef

_proc(x::PyRef) = getfield(x, :proc)
_ref(x::PyRef) = getfield(x, :ref)

_finalize_pyref(x::PyRef) = send(_proc(x), (; tag="delref", ref=_ref(x)))

Base.string(x::PyRef) = pyrun(_proc(x), "jl.ret(str(x), 'str')", locals=(; x))::String

Base.print(io::IO, x::PyRef) = print(io, string(x))

function Base.show(io::IO, x::PyRef)
    s = pyrun(_proc(x), "jl.ret(repr(x), 'str')", locals=(; x))::String
    print(io, "PyRef: ", s)
end

function Base.propertynames(x::PyRef, private::Bool=false)
    return map(Symbol, pyrun(_proc(x), "jl.ret(dir(x), ('list', 'str'))", locals=(; x))::Vector{String})
end

function Base.getproperty(x::PyRef, k::Symbol)
    return pyrun(_proc(x), "jl.ret(getattr(x, k), 'ref')", locals=(; x, k))::PyRef
end

function Base.setproperty!(x::PyRef, k::Symbol, v)
    return pyrun(_proc(x), "setattr(x, k, v)", locals=(; x, k, v))::Nothing
end

function (f::PyRef)(args...; kw...)
    return pyrun(_proc(f), "jl.ret(f(*args, **kwargs), 'ref')", locals=(; f, args, kwargs=NamedTuple(kw)))::PyRef
end

function Base.getindex(x::PyRef, k)
    return pyrun(_proc(x), "jl.ret(x[k], 'ref')", locals=(; x, k))::PyRef
end

function Base.getindex(x::PyRef, k...)
    return getindex(x, k)
end

function Base.setindex!(x::PyRef, v, k)
    pyrun(_proc(x), "x[k] = v", locals=(; x, k, v))::Nothing
    return x
end

function Base.setindex!(x::PyRef, v, k...)
    return setindex!(x, v, k)
end

function Base.delete!(x::PyRef, k)
    pyrun(_proc(x), "del x[k]", locals=(; x, k))::Nothing
    return x
end

function Base.length(x::PyRef)
    return pyrun(_proc(x), "jl.ret(len(x), 'int')", locals=(; x))::Int
end

end # module
