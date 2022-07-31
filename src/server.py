import asyncio
import sys
import json
import collections.abc
import numbers

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

class IntFormat(Format):
    def _format(self, value):
        value = int(value)
        if abs(value) < (1<<20):
            return value
        else:
            return {'t': 'int', 'v': str(value)}

class FloatFormat(Format):
    def _format(self, value):
        value = float(value)
        return {'t': 'float', 'v': str(value)}

class UnionFormat(Format):
    def __init__(self, *formats, **kw):
        self.formats = [NoneFormat() if fmt is None else fmt for fmt in formats]
        super().__init__(**kw)
    def _format(self, value):
        for fmt in self.formats:
            try:
                return fmt.format(value)
            except TypeError:
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
        self.keyfmt = keyfmt
        self.valfmt = valfmt
        super().__init__(**kw)
    def _format(self, value):
        fk = self.keyfmt.format
        fv = self.valfmt.format
        return {'t': 'dict', 'v': [(fk(k), fv(v)) for (k, v) in value.items()]}

class ListFormat(Format):
    def __init__(self, elfmt=AnyFormat(), **kw):
        self.elfmt = elfmt
        super().__init__(**kw)
    def _format(self, value):
        f = self.elfmt.format
        return {'t': 'list', 'v': [f(x) for x in value]}

ANY_FORMAT.formats.extend([
    NoneFormat(),
    BoolFormat(isa=bool),
    StrFormat(isa=str),
    IntFormat(isa=numbers.Integral),
    FloatFormat(isa=float),
    DictFormat(isa=collections.abc.Mapping),
    ListFormat(isa=collections.abc.Sequence),
    RefFormat(),
])

def ret(val=None, fmt=AnyFormat()):
    raise Result(fmt.format(val))

jl = type(sys)(__name__ + '.jl')
jl.ret = ret
jl.ret_ref = lambda val: ret(val, RefFormat())
jl.Bool = BoolFormat
jl.Str = StrFormat
jl.Union = UnionFormat
jl.Optional = OptionalFormat
jl.Any = AnyFormat
jl.Int = IntFormat
jl.Float = FloatFormat
jl.Ref = RefFormat
jl.List = ListFormat

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
        sys.stdout.flush()
        sys.stderr.flush()
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
    try:
        server = await asyncio.start_server(serve, '127.0.0.1', 8888)
    except Exception as exc:
        print(json.dumps({'status': 'ERROR', 'msg': str(exc)}))
        sys.stdout.flush()
        return
    print(json.dumps({'status': 'READY', 'addr': '127.0.0.1', 'port': 8888}))
    sys.stdout.flush()
    debug('serving...')
    async with server:
        await server.serve_forever()

asyncio.run(start_server())
