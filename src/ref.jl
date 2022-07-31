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
