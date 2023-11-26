import asyncio
import sys
import json
import collections.abc
import numbers
import base64
import io
import random

DEBUG = False
def debug(*args, force=False):
    if DEBUG or force:
        print(*args, file=sys.stderr)

async def recv(fp):
    line = await fp.readline()
    if line:
        return json.loads(line.decode('utf8'))

async def send(fp, msg):
    line = (json.dumps(msg) + '\n').encode('utf8')
    fp.write(line)
    await fp.drain()

background_tasks = set()
def run_in_background(co):
    task = asyncio.create_task(co)
    background_tasks.add(task)
    task.add_done_callback(background_tasks.discard)

async def sleep_echo(writer, msg):
    debug('sleeping...')
    await asyncio.sleep(msg['sleep'])
    debug('echo...')
    await send(writer, msg)

scopes = {}
def get_scope(name):
    if name.startswith('@'):
        name = __name__ + '.scopes.' + name[1:]
        if name not in sys.modules:
            sys.modules[name] = type(sys)(name)
    return sys.modules[name].__dict__

refid = 0
refs = {}
def get_ref(value):
    global refid
    refid += 1
    r = str(refid)
    refs[r] = value
    return r

def del_ref(r):
    refs.pop(r, None)

class Result(Exception):
    pass

FORMATS = {}
def to_format(x):
    if isinstance(x, Format):
        return x
    if isinstance(x, tuple):
        args = x[1:]
        x = x[0]
    else:
        args = ()
    if isinstance(x, str):
        x = FORMATS[x]
    return x(*args)

class Format:
    def __init__(self, isa=None):
        self.isa = isa
    def format(self, value):
        isa = self.isa
        if isa is not None and not isinstance(value, isa):
            raise TypeError(f'expecting a {isa}')
        return self._format(value)

class NoneFormat(Format):
    def _format(self, value):
        if value is not None:
            raise TypeError('expecting None')
        return None

class BoolFormat(Format):
    def _format(self, value):
        return bool(value)

class StrFormat(Format):
    def _format(self, value):
        return str(value)

class BytesFormat(Format):
    def _format(self, value):
        return {'t': 'bytes', 'v': base64.b64encode(bytes(value)).decode('ascii')}

class IntFormat(Format):
    def _format(self, value):
        value = int(value)
        if abs(value) < (1<<20):
            return value
        else:
            return {'t': 'int', 'v': str(value)}

class RationalFormat(Format):
    def _format(self, value):
        return {'t': 'rational', 'v': [str(int(value.numerator)), str(int(value.denominator))]}

class FloatFormat(Format):
    def _format(self, value):
        value = float(value)
        return {'t': 'float', 'v': str(value)}

class UnionFormat(Format):
    def __init__(self, *formats, **kw):
        self.formats = [to_format(f) for f in formats]
        super().__init__(**kw)
    def _format(self, value):
        for fmt in self.formats:
            try:
                return fmt.format(value)
            except (TypeError, ValueError):
                pass
        raise TypeError('cannot format this')

ANY_FORMAT = UnionFormat()
def AnyFormat():
    return ANY_FORMAT

def OptionalFormat(*formats):
    return UnionFormat(NoneFormat(), *formats)

class RefFormat(UnionFormat):
    def _format(self, value):
        return {'t': 'ref', 'v': get_ref(value)}

class DictFormat(Format):
    def __init__(self, keyfmt=AnyFormat(), valfmt=AnyFormat(), **kw):
        self.keyfmt = to_format(keyfmt)
        self.valfmt = to_format(valfmt)
        super().__init__(**kw)
    def _format(self, value):
        fk = self.keyfmt.format
        fv = self.valfmt.format
        return {'t': 'dict', 'v': [(fk(k), fv(v)) for (k, v) in value.items()]}

class ListFormat(Format):
    def __init__(self, elfmt=AnyFormat(), **kw):
        self.elfmt = to_format(elfmt)
        super().__init__(**kw)
    def _format(self, value):
        f = self.elfmt.format
        return {'t': 'list', 'v': [f(x) for x in value]}

class SetFormat(Format):
    def __init__(self, elfmt=AnyFormat(), **kw):
        self.elfmt = to_format(elfmt)
        super().__init__(**kw)
    def _format(self, value):
        f = self.elfmt.format
        return {'t': 'set', 'v': [f(x) for x in value]}

class TupleFormat(Format):
    def __init__(self, elfmt=AnyFormat(), **kw):
        if isinstance(elfmt, list):
            self.elfmt = [to_format(f) for f in elfmt]
        else:
            self.elfmt = to_format(elfmt)
        super().__init__(**kw)
    def _format(self, value):
        value = tuple(value)
        elfmt = self.elfmt
        if isinstance(elfmt, list):
            if len(elfmt) != len(value):
                raise TypeError('tuple is incorrect length')
            return {'t': 'tuple', 'v': [f.format(x) for (f, x) in zip(elfmt, value)]}
        else:
            f = elfmt.format
            return {'t': 'tuple', 'v': [f(x) for x in value]}

class BufferFormat(Format):
    def _format(self, value):
        m = memoryview(value)
        assert m.ndim == len(m.shape)
        data = m.tobytes(order='F')
        assert m.nbytes == len(data)
        return {
            't': 'buffer',
            'v': {
                'format': m.format,
                'itemsize': m.itemsize,
                'nbytes': m.nbytes,
                'ndim': m.ndim,
                'shape': m.shape,
                'data': base64.b64encode(data).decode('ascii'),
            }
        }

class NDArrayFormat(Format):
    def __init__(self, ndim=None, isarray=False, **kw):
        self.ndim = ndim
        self.isarray = isarray
        super().__init__(**kw)
    def _format(self, value):
        if self.isarray:
            t = type(value)
            if (getattr(t, '__array__', None) is None and
                getattr(t, '__array_struct__', None) is None and
                getattr(t, '__array_interface__', None) is None
            ):
                raise TypeError('not an array')
        import numpy.lib.format
        arr = numpy.array(value, ndmin=self.ndim or 0)
        if self.ndim is not None and self.ndim != arr.ndim:
            raise TypeError('incorrect number of dimensions')
        data = arr.tobytes(order='F')
        dtype = arr.dtype
        if dtype.hasobject:
            raise TypeError('cannot serialise arrays containing Python objects (must be plain bits)')
        assert arr.ndim == len(arr.shape)
        return {
            't': 'ndarray',
            'v': {
                'dtype': numpy.lib.format.dtype_to_descr(arr.dtype),
                'ndim': arr.ndim,
                'shape': arr.shape,
                'data': base64.b64encode(data).decode('ascii'),
            },
        }

class BaseMediaFormat(Format):
    def __init__(self, mimes, **kw):
        if isinstance(mimes, str):
            mimes = [mimes]
        else:
            mimes = list(mimes)
        self.mimes = mimes
        super().__init__(**kw)

class MimebundleMediaFormat(BaseMediaFormat):
    def _format(self, value):
        try:
            ans = type(value)._repr_mimebundle_(value, include=self.mimes)
            if isinstance(ans, tuple):
                ans = ans[0]
            mimes = [mime for mime in self.mimes if mime in ans]
            mime = mimes[0]
            ans = ans[mime]
            if isinstance(ans, str):
                ans = ans.encode('utf-8')
            return {
                't': 'media',
                'v': {
                    'mime': mime,
                    'data': base64.b64encode(ans).decode('ascii'),
                }
            }
        except:
            raise TypeError('not supported')

REPR_METHODS = {
    "text/plain": "__repr__",
    "text/html": "_repr_html_",
    "text/markdown": "_repr_markdown_",
    "text/json": "_repr_json_",
    "text/latex": "_repr_latex_",
    "application/javascript": "_repr_javascript_",
    "application/pdf": "_repr_pdf_",
    "image/jpeg": "_repr_jpeg_",
    "image/png": "_repr_png_",
    "image/svg+xml": "_repr_svg_",
}

class ReprMediaFormat(BaseMediaFormat):
    def _format(self, value):
        for mime in self.mimes:
            try:
                method = REPR_METHODS[mime]
                ans = getattr(type(value), method)(value)
                if isinstance(ans, tuple):
                    ans = ans[0]
                if isinstance(ans, str):
                    ans = ans.encode('utf-8')
                return {
                    't': 'media',
                    'v': {
                        'mime': mime,
                        'data': base64.b64encode(ans).decode('ascii'),
                    }
                }
            except Exception:
                pass
        raise TypeError('not supported')

PYPLOT_FORMATS = {
    'image/png': 'png',
    'image/jpeg': 'jpeg',
    'image/tiff': 'tiff',
    'image/svg+xml': 'svg',
    'application/pdf': 'pdf',
}

class PyplotMediaFormat(BaseMediaFormat):
    def _format(self, value):
        try:
            if 'matplotlib' not in sys.modules:
                raise TypeError()
            import matplotlib.pyplot as plt
            fig = value
            while not isinstance(fig, plt.Figure):
                fig = fig.figure
            for mime in self.mimes:
                try:
                    fmt = PYPLOT_FORMATS[mime]
                    buf = io.BytesIO()
                    fig.savefig(buf, format=fmt, bbox_inches='tight')
                    plt.close(fig)
                    return {
                        't': 'media',
                        'v': {
                            'mime': mime,
                            'data': base64.b64encode(buf.getvalue()).decode('ascii'),
                        }
                    }
                except Exception:
                    raise TypeError()
        except Exception:
            raise TypeError('not supported')

class BokehMediaFormat(BaseMediaFormat):
    def _format(self, value):
        if 'text/html' not in self.mimes:
            raise TypeError('only text/html is supported')
        try:
            if 'bokeh' not in sys.modules:
                raise TypeError()
            from bokeh.models import LayoutDOM
            from bokeh.embed.standalone import autoload_static
            from bokeh.resources import CDN
            if not isinstance(value, LayoutDOM):
                raise TypeError()
            script, html = autoload_static(value, CDN, '')
            # TODO: this is quick hacky
            src = ' src=""'
            endscript = '</script>'
            assert src in html
            assert endscript in html
            html = html.replace(' src=""', '')
            html = html.replace(endscript, script.strip()+endscript)
            return {
                't': 'media',
                'v': {
                    'mime': 'text/html',
                    'data': base64.b64encode(html.encode('utf-8')).decode('ascii')
                }
            }
        except Exception:
            raise TypeError('not supported')

MEDIA_FORMATS = [
    BokehMediaFormat,
    PyplotMediaFormat,
    MimebundleMediaFormat,
    ReprMediaFormat,
]
def MediaFormat(*args, **kw):
    return UnionFormat(*[t(*args, **kw) for t in MEDIA_FORMATS])

ANY_FORMAT.formats.extend([
    NoneFormat(),
    BoolFormat(isa=bool),
    StrFormat(isa=str),
    BytesFormat(isa=(bytes,bytearray)),
    IntFormat(isa=numbers.Integral),
    RationalFormat(isa=numbers.Rational),
    FloatFormat(isa=numbers.Real),
    DictFormat(isa=collections.abc.Mapping),
    TupleFormat(isa=tuple),
    ListFormat(isa=collections.abc.Sequence),
    SetFormat(isa=collections.abc.Set),
    NDArrayFormat(isarray=True),
    RefFormat(),
])

def ret(val=None, fmt='any'):
    raise Result(to_format(fmt).format(val))

FORMATS['none'] = NoneFormat
FORMATS['bool'] = BoolFormat
FORMATS['str'] = StrFormat
FORMATS['union'] = UnionFormat
FORMATS['optional'] = OptionalFormat
FORMATS['any'] = AnyFormat
FORMATS['int'] = IntFormat
FORMATS['rational'] = RationalFormat
FORMATS['float'] = FloatFormat
FORMATS['ref'] = RefFormat
FORMATS['list'] = ListFormat
FORMATS['tuple'] = TupleFormat
FORMATS['set'] = SetFormat
FORMATS['bytes'] = BytesFormat
FORMATS['buffer'] = BufferFormat
FORMATS['array'] = NDArrayFormat
FORMATS['media/bokeh'] = BokehMediaFormat
FORMATS['media/pyplot'] = PyplotMediaFormat
FORMATS['media/repr'] = ReprMediaFormat
FORMATS['media/mimebundle'] = MimebundleMediaFormat
FORMATS['media'] = MediaFormat
FORMATS['png'] = lambda: MediaFormat('image/png')
FORMATS['html'] = lambda: MediaFormat('text/html')
FORMATS['jpeg'] = lambda: MediaFormat('image/jpeg')
FORMATS['tiff'] = lambda: MediaFormat('image/tiff')
FORMATS['svg'] = lambda: MediaFormat('image/svg+xml')
FORMATS['pdf'] = lambda: MediaFormat('application/pdf')

jl = type(sys)(__name__ + '.jl')
jl.ret = ret

def get_locals(lcls):
    if lcls is None:
        return None
    ans = {'jl': jl}
    for (k, v) in lcls.items():
        ans[k] = get_local(v)
    return ans

def get_local(v):
    if v is None or v is True or v is False or isinstance(v, (int, str)):
        return v
    assert isinstance(v, dict)
    t = v['t']
    v = v['v']
    if t == 'ref':
        return refs[v]
    elif t == 'tuple':
        return tuple(get_local(x) for x in v)
    elif t == 'list':
        return [get_local(x) for x in v]
    elif t == 'int':
        return int(v)
    elif t == 'float':
        return float(v)
    elif t == 'dict':
        return {get_local(k): get_local(v) for (k, v) in v}
    assert False

async def do_run(writer, msg):
    try:
        code = msg['code']
        gbls = get_scope(msg['scope'])
        lcls = get_locals(msg['locals'])
        exec(code, gbls, lcls)
        out = {
            'tag': 'result',
            'result': None,
        }
    except Result as exc:
        out = {
            'tag': 'result',
            'result': exc.args[0],
        }
    except BaseException as exc:
        out = {
            'tag': 'error',
            'type': type(exc).__name__,
            'str': str(exc),
        }
    sys.stdout.flush()
    sys.stderr.flush()
    out['id'] = msg['id']
    await send(writer, out)

async def serve(reader, writer):
    while True:
        debug('next iteration...')
        msg = await recv(reader)
        debug('got message', repr(msg))
        if msg is None:
            debug('connection closed')
            break
        tag = msg['tag']
        if tag == 'echo':
            debug('echo...')
            await send(writer, msg)
        elif tag == 'sleep-echo':
            debug('sleep-echo...')
            run_in_background(sleep_echo(writer, msg))
        elif tag == 'stop':
            break
        elif tag == 'run':
            debug('run...')
            run_in_background(do_run(writer, msg))
        elif tag == 'delref':
            debug('delref...')
            del_ref(msg['ref'])
    writer.close()

async def start_server():
    debug('starting server...')
    ntries = 10
    for ntry in range(ntries):
        port = random.randrange(49152, 65536)
        try:
            server = await asyncio.start_server(serve, '127.0.0.1', port)
            break
        except Exception as exc:
            if ntry < ntries - 1 and isinstance(exc, OSError):
                continue
            print(json.dumps({'status': 'ERROR', 'msg': str(exc)}))
            sys.stdout.flush()
            return
    print(json.dumps({'status': 'READY', 'addr': '127.0.0.1', 'port': port}))
    sys.stdout.flush()
    debug('serving...')
    async with server:
        await server.serve_forever()

asyncio.run(start_server())
