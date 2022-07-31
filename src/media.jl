function _show_media(io, media)
    write(io, media.data)
    return
end

Base.show(io::IO, mime::M, media::PyMedia{M}) where {M<:MIME} = _show_media(io, media)
Base.show(io::IO, ::MIME"text/plain", media::PyMedia{MIME"text/plain"}) = _show_media(io, media)
