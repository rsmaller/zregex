from ctypes import *
import platform, sys

zregex_dylib = None

if platform.system() == "Windows":
    zregex_dylib = cdll.LoadLibrary("./c-out/zregex.dll")
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


# True internal functions.

def _zig_io_callback_fn(string, length: c_size_t):
    to_print = str(string_at(string, int(length)).decode('utf-8'))
    sys.stdout.write(to_print)
    sys.stdout.flush()

# Internal functions used in python wrappers in __init__

def to_c_str_internal(string):
    return c_char_p(string.encode('utf-8'))

callback_internal = ZRegexCallbackFn(_zig_io_callback_fn) # Store in global scope so that the function isn't garbage collected.
callback_internal.argtypes = [c_char_p, c_size_t] # Here to match format of other decls.
callback_internal.restype = None

destroy_pattern_internal = zregex_dylib.zregex_destroy_pattern # _destroy functions are to be used during garbage collection.
destroy_pattern_internal.argtypes = [c_void_p]
destroy_pattern_internal.restype = None

destroy_match_internal = zregex_dylib.zregex_destroy_match
destroy_match_internal.argtypes = [POINTER(InternalMatch)]
destroy_match_internal.restype = None

destroy_name_internal = zregex_dylib.zregex_destroy_name
destroy_name_internal.argtypes = [c_char_p]
destroy_name_internal.restype = None

compile_internal = zregex_dylib.zregex_compile
compile_internal.argtypes = [c_char_p]
compile_internal.restype = c_void_p

match_internal = zregex_dylib.zregex_match
match_internal.argtypes = [c_void_p, c_char_p]
match_internal.restype = POINTER(InternalMatch)

print_bytecode_internal = zregex_dylib.zregex_print_bytecode
print_bytecode_internal.argtypes = [c_void_p]
print_bytecode_internal.restype = None

print_ast_internal = zregex_dylib.zregex_print_ast
print_ast_internal.argtypes = [c_void_p, ASTPrintOptions]
print_ast_internal.restype = None

print_test_internal = zregex_dylib.zregex_print_test
print_test_internal.argtypes = []
print_test_internal.restype = None

name_index_internal = zregex_dylib.zregex_name_index
name_index_internal.argtypes = [c_void_p, c_char_p]
name_index_internal.restype = c_char_p

id_index_internal = zregex_dylib.zregex_id_index
id_index_internal.argtypes = [c_void_p, c_size_t]
id_index_internal.restype = c_char_p

name_to_id_internal = zregex_dylib.zregex_name_to_id
name_to_id_internal.argtypes = [c_void_p, c_char_p]
name_to_id_internal.restype = ZOptional_size_t

id_to_name_internal = zregex_dylib.zregex_id_to_name
id_to_name_internal.argtypes = [c_void_p, c_size_t]
id_to_name_internal.restype = c_char_p

init_internal = zregex_dylib.zregex_init_python
init_internal.argtypes = [c_void_p]
init_internal.restype = None

