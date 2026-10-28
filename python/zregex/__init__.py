from ctypes import *
from zregex import *
import zregex._zregex

class Match:
    def __init__(self, match_ptr: POINTER(_zregex.InternalMatch)):
        self.pattern = match_ptr.contents.pattern_ptr
        self.groups = []
        for i in range(match_ptr.contents.group_count):
            self.groups.append(_zregex._id_index(match_ptr, i).decode('utf-8'))

class Pattern:
    def __init__(self, pattern_ptr: c_void_p):
        self.pattern = pattern_ptr
    def __del__(self):
        _zregex._destroy_pattern(self.pattern) # Internal AST in zig must be kept active past compilation point.

def init(): # Hooks into _zregex._callback defined below.
    _zregex._init(_zregex._callback)

def compile(string: str):
    ret = _zregex._compile(_zregex._to_c_str(string))
    if ret is None:
        raise Exception("Unable to compile target string")
    return Pattern(ret)

def match(pattern: Pattern, string: str):
    item = _zregex._match(pattern.pattern, _zregex._to_c_str(string))
    if item is None:
        return None
    ret = Match(item)
    _zregex._destroy_match(item) # Zig's allocated match is immediately destroyed.
    return ret

def print_bytecode(pattern: Pattern):
    return _zregex._print_bytecode(pattern.pattern)

def print_ast(pattern: Pattern, show_len: bool):
    options = _zregex.ASTPrintOptions()
    options.show_match_width = show_len
    return _zregex._print_ast(pattern.pattern, options)

def print_test():
    return _zregex._print_test()

# Requires heap-allocated names.
# def name_index(match_ptr: c_void_p, name: str):
#     if match_ptr is None:
#         return None
#     return _zregex._name_index(match_ptr, _zregex._to_c_str(name)).decode('utf-8')

# def id_index(match_ptr: c_void_p, id: int):
#     if match_ptr is None:
#         return None
#     if id < 0:
#         raise Exception("Group ID must be a valid unsigned value")
#     ret = _zregex._id_index(match_ptr, c_size_t(id))
#     if not ret:
#         return ret
#     else:
#         return ret.decode('utf-8')

# Requires heap-allocated names.
# def name_to_id(pattern: c_void_p, name: str): # Unpacks optional ID struct to a value or None.
#     if pattern is None:
#         return None
#     id: ZOptional_size_t = _zregex._name_to_id(pattern, _zregex._to_c_str(name))
#     if id.present:
#         return id.value
#     else:
#         return None

# Requires heap-allocated names.
# def id_to_name(pattern: c_void_p, id: int):
#     if pattern is None:
#         return None
#     if id < 0:
#         raise Exception("Group ID must be a valid unsigned value")
#     name: c_char_p = _zregex._id_to_name(pattern, c_size_t(id))
#     return repr(name)
