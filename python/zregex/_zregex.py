from ctypes import *
import platform

zregex = None

if platform.system() == "Windows":
    zregex = cdll.LoadLibrary("./c-out/zregex.dll")
elif platform.system() == "Darwin":
    zregex = cdll.LoadLibrary("./c-out/libzregex.dylib")
else:
    zregex = cdll.LoadLibrary("./c-out/libzregex.so")

class Match(Structure): # typedef struct match in header.
    _fields_ = [ ("groups", POINTER(POINTER(c_char))), ("pattern_ptr", c_void_p) ]

# typedef size_t (*CallbackFunc)(const void *, size_t, size_t, FILE *);

class ZOptional_size_t(Structure):
    _fields_ = [ ("value", c_size_t) , ("present", c_bool) ]

class ASTPrintOptions(Structure):
    _fields_ = [ ("show_match_width", c_bool) ]

def to_c_str(string):
    return c_char_p(string.encode('utf-8'))

compile = zregex.zregex_compile
compile.argtypes = [c_char_p]
compile.restype = c_void_p

match = zregex.zregex_match
match.argtypes = [c_void_p, c_char_p]
match.restype = POINTER(Match)

destroy_pattern = zregex.zregexdestroy_pattern
destroy_pattern.argtypes = [c_void_p]
destroy_pattern.restype = None

destroy_match = zregex.zregexdestroy_match
destroy_match.argtypes = [POINTER(Match)]
destroy_match.restype = None

# init = zr

print_bytecode = zregex.zregex_print_bytecode
print_bytecode.argtypes = [c_void_p]
print_bytecode.restype = None

print_ast = zregex.zregex_print_ast
print_ast.argtypes = [c_void_p]
print_ast.restype = None

name_index = zregex.zregex_name_index
name_index.argtypes = [c_void_p, c_char_p]
name_index.restype = c_char_p

id_index = zregex.zregex_id_index
id_index.argtypes = [c_void_p, c_size_t]
id_index.restype = c_char_p

name_to_id = zregex.zregex_name_to_id
name_to_id.argtypes = [c_void_p, c_char_p]
name_to_id.restype = c_size_t

id_to_name = zregex.zregex_id_to_name
name_to_id.argtypes = [c_void_p, c_size_t]
name_to_id.restype = c_char_p

destroy_name = zregex.zregex_destroy_name

test = compile(to_c_str("\\w+"))
mymatch = match(c_void_p(test), to_c_str("abc"))

print(id_index(mymatch, 0))

destroy_match(mymatch)
destroy_pattern(test)