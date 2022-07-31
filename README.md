# PyRun.jl

Another Python-Julia interoperability package. It's a simple as:
```julia
using PyRun
pyrun("print('Hello from Python!')")
```

This differs from `PythonCall` and `PyCall` in that those packages embed the Python
interpreter into the current process, whereas `PyRun` launches a new Python process and
communicates with that.

Advantages of this approach are:
- Library mismatches do not occur, such as when Julia and Python require different versions
  of LLVM.
- Other implementations of Python can be used, such as PyPy.
- Python's multithreading and multiprocessing works without issue.
- Asynchronous Julia and Python code both work and can be mixed.
- You can easily use multiple Python processes - construct more with `PyProcess()` and pass
  them as the first argument to `pyrun`.

Disadvantages are:
- Inter-process communication is slow (rougly 200μs per run), so you should not write tight
  loops in Julia which call Python.
- No shared memory, since Python is running in a separate process. (But you could use
  something like Apache Arrow to work.)

## Install

```
pkg> add https://github.com/cjdoris/PyRun.jl
```

## Usage

```julia
pyrun([p::PyProcess], code; scope, locals)
```

Run the given piece of Python `code`.

If the process is not specified, a global default process is used.

The scope defines the module in which the code is run. It may be of the form "@name" to
create a new module in a separate namespace.

The locals is a named tuple or dict defining the locals when running the code. May also be
`nothing` to run the code in global scope.

The module `jl` is available to the code. You may call `jl.ret(x)` to return `x` from the
code. You can control the returned format with `jl.ret(x, fmt)`, such as
`jl.ret(x, jl.Int())`.

## Examples

A simple print statement:
```julia
julia> pyrun("print('hello world!')")
hello world!
```

Say hello the given user:
```julia
julia> pyrun("print('hello', name)", locals=(name="alice",))
hello alice
```

Do some arithmetic and return the answer (converted automatically to Int):
```julia
julia> pyrun("jl.ret(x + y)", locals=(x=1, y=2))
3
```

Make and return a Python list (converted automatically to a vector):
```julia
julia> pyrun("jl.ret([1, 2, 3])")
3-element Vector{Int64}:
 1
 2
 3
```

Explicitly convert to a PyRef (supports attributes, indexing, calling, etc.):
```julia
julia> x = pyrun("jl.ret([1, 2, 3], jl.Ref())")
PyRef: [1, 2, 3]

julia> length(x)
3

julia> x[2]
PyRef: 3

julia> x.append(4)
PyRef: None

julia> x
PyRef: [1, 2, 3, 4]
```
