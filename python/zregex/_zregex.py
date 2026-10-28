from ctypes import *
import platform, sys

zregex_dylib = None

if platform.system() == "Windows":
    zregex_dylib = cdll.LoadLibrary("./c-out/zregex_dylib.dll")
elif platform.system() == "Darwin":
    zregex_dylib = cdll.LoadLibrary("./c-out/libzregex.dylib")
else:
    zregex_dylib = cdll.LoadLibrary("./c-out/libzregex.so")

# Data types.
class InternalMatch(Structure): # typedef struct match in header.
    _fields_ = [ ("groups", POINTER(POINTER(c_char))), ("pattern_ptr", c_void_p), ("group_count", c_size_t) ]

class ZOptional_size_t(Structure):
    _fields_ = [ ("value", c_size_t) , ("present", c_bool) ]

class ASTPrintOptions(Structure):
    _fields_ = [ ("show_match_width", c_bool) ]

ZRegexCallbackFn = CFUNCTYPE(None, POINTER(c_char), c_size_t) # cannot use c_char_p due to null termination.

# Internal functions.
def _to_c_str(string):
    return c_char_p(string.encode('utf-8'))

def _zig_io_callback_fn(string: POINTER(c_char), length: c_size_t):
    to_print = str(string_at(string, int(length)).decode('utf-8'))
    sys.stdout.write(to_print)
    sys.stdout.flush()

_callback = ZRegexCallbackFn(_zig_io_callback_fn) # Store in global scope so that the function isn't garbage collected.
_callback.argtypes = [c_char_p, c_size_t] # Here to match format of other decls.
_callback.restype = None

_destroy_pattern = zregex_dylib.zregex_destroy_pattern # _destroy functions are to be used during garbage collection.
_destroy_pattern.argtypes = [c_void_p]
_destroy_pattern.restype = None

_destroy_match = zregex_dylib.zregex_destroy_match
_destroy_match.argtypes = [POINTER(InternalMatch)]
_destroy_match.restype = None

_destroy_name = zregex_dylib.zregex_destroy_name
_destroy_name.argtypes = [c_char_p]
_destroy_name.restype = None

_compile = zregex_dylib.zregex_compile
_compile.argtypes = [c_char_p]
_compile.restype = c_void_p

_match = zregex_dylib.zregex_match
_match.argtypes = [c_void_p, c_char_p]
_match.restype = POINTER(InternalMatch)

_print_bytecode = zregex_dylib.zregex_print_bytecode
_print_bytecode.argtypes = [c_void_p]
_print_bytecode.restype = None

_print_ast = zregex_dylib.zregex_print_ast
_print_ast.argtypes = [c_void_p, ASTPrintOptions]
_print_ast.restype = None

_print_test = zregex_dylib.zregex_print_test
_print_test.argtypes = []
_print_test.restype = None

_name_index = zregex_dylib.zregex_name_index
_name_index.argtypes = [c_void_p, c_char_p]
_name_index.restype = c_char_p

_id_index = zregex_dylib.zregex_id_index
_id_index.argtypes = [c_void_p, c_size_t]
_id_index.restype = c_char_p

_name_to_id = zregex_dylib.zregex_name_to_id
_name_to_id.argtypes = [c_void_p, c_char_p]
_name_to_id.restype = ZOptional_size_t

_id_to_name = zregex_dylib.zregex_id_to_name
_id_to_name.argtypes = [c_void_p, c_size_t]
_id_to_name.restype = c_char_p

_init = zregex_dylib.zregex_init_python
_init.argtypes = [c_void_p]
_init.restype = None

