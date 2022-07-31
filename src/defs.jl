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

struct PyBuffer
    format::String
    itemsize::Int
    shape::Vector{Int}
    data::Vector{UInt8}
end

struct PyMedia{M<:MIME}
    data::Vector{UInt8}
end

const PyPNG = PyMedia{MIME"image/png"}
const PyHTML = PyMedia{MIME"text/html"}
const PyJPEG = PyMedia{MIME"image/jpeg"}
const PyTIFF = PyMedia{MIME"image/tiff"}
const PySVG = PyMedia{MIME"image/svg+xml"}
const PyPDF = PyMedia{MIME"application/pdf"}
