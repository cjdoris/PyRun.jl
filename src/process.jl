const SERVER_PY = joinpath(@__DIR__, "server.py")

Base.show(io::IO, p::PyProcess) = print(io, "PyProcess()")

function _finalize_pyprocess(p::PyProcess)
    isopen(p) && close(p)
    return
end

Base.isopen(p::PyProcess) = isopen(p.proc) && isopen(p.sock)
Base.close(p::PyProcess) = (send(p, (; tag="close")); close(p.sock); close(p.proc); kill(p.proc); nothing)

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

function _parse_buffer(v)
    buf = PyBuffer(
        v.format,
        v.itemsize,
        v.shape,
        Base64.base64decode(v.data),
    )
    v.ndim == length(buf.shape) || error("length(shape)=$(length(buf.shape)) but ndim=$(v.ndim)")
    v.nbytes == length(buf.data) || error("length(data)=$(length(buf.data)) but nbytes=$(v.nbytes)")
    return buf
end

function dtype_to_type(dt)
    if dt isa String
        # check byte-order
        oc = dt[1]
        if oc in "<>"
            if oc != (Base.ENDIAN_BOM == 0x04030201 ? '<' : '>')
                error("unsupported: byte-swapped dtype=$dt")
            end
        elseif oc != '|'
            error("unsupported order char $oc in dtype=$dt")
        end
        # parse type
        tc = dt[2]
        sz = dt[3:end]
        if tc == 'f'
            if sz == "2"
                return Float16
            elseif sz == "4"
                return Float32
            elseif sz == "8"
                return Float64
            end
        elseif tc == 'i'
            if sz == "1"
                return Int8
            elseif sz == "2"
                return Int16
            elseif sz == "4"
                return Int32
            elseif sz == "8"
                return Int64
            end
        elseif tc == 'u'
            if sz == "1"
                return UInt8
            elseif sz == "2"
                return UInt16
            elseif sz == "4"
                return UInt32
            elseif sz == "8"
                return UInt64
            end
        elseif tc == 'c'
            if sz == "4"
                return ComplexF16
            elseif sz == "8"
                return ComplexF32
            elseif sz == "16"
                return ComplexF64
            end
        elseif tc == 'b'
            if sizeof(Bool) == 1 && sz == "1"
                return Bool
            end
        end
    end
    error("unsupported dtype: $dt")
end

function _parse_ndarray(v)
    T = dtype_to_type(v.dtype::String)::Type
    N = v.ndim::Int
    sz = NTuple{N,Int}(v.shape)
    return Array(reshape(reinterpret(T, Base64.base64decode(v.data::String)), sz))::Array
end

function _parse_media(v)
    mime = typeof(MIME(v[:mime]::String))
    data = Base64.base64decode(v[:data]::String)
    return PyMedia{mime}(data)
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
    elseif t == "buffer"
        return _parse_buffer(v::JSON3.Object)
    elseif t == "ndarray"
        return _parse_ndarray(v::JSON3.Object)
    elseif t == "media"
        return _parse_media(v::JSON3.Object)
    else
        return res
    end
end
