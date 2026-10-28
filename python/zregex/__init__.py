from ctypes import *
from .zregex import *

class Match:
    def __init__(self, match_ptr):
        self.pattern = match_ptr.contents.pattern_ptr
        self.groups = []
        for i in range(match_ptr.contents.group_count):
            self.groups.append(id_index_internal(match_ptr, i).decode('utf-8'))
    def __getitem__(self, key):
        if isinstance(key, int):
            return self.groups[key]
        elif isinstance(key, str):
            if self.pattern is None:
                return None
            # id: ZOptional_size_t = name_to_id_internal(self.pattern, to_c_str_internal(key))
            # if id.present:
            #     return self.groups[id]
            else:
                return None
        else:
            raise Exception("Invalid value passed to get item method!")

class Pattern:
    def __init__(self, pattern_ptr: c_void_p):
        self.pattern = pattern_ptr
    def __del__(self):
        destroy_pattern_internal(self.pattern) # Internal AST in zig must be kept active past compilation point.

def init(): # Hooks into _callback defined below.
    zregex.init_internal(zregex.callback_internal)

def compile(string: str):
    ret = zregex.compile_internal(zregex.to_c_str_internal(string))
    if ret is None:
        raise Exception("Unable to compile target string")
    return Pattern(ret)

def match(pattern: Pattern, string: str):
    item = zregex.match_internal(pattern.pattern, to_c_str_internal(string))
    if item is None:
        return None
    ret = Match(item)
    destroy_match_internal(item) # Zig's allocated match is immediately destroyed.
    return ret

def print_bytecode(pattern: Pattern):
    return zregex.print_bytecode_internal(pattern.pattern)

def print_ast(pattern: Pattern, show_len: bool):
    options = zregex.ASTPrintOptions()
    options.show_match_width = show_len
    return zregex.print_ast_internal(pattern.pattern, options)

def print_test():
    return zregex.print_test_internal()

# Requires heap-allocated names.
# def name_index(match_ptr: c_void_p, name: str):
#     if match_ptr is None:
#         return None
#     return name_index_internal(match_ptr, _to_c_str(name)).decode('utf-8')

# def id_index(match_ptr: c_void_p, id: int):
#     if match_ptr is None:
#         return None
#     if id < 0:
#         raise Exception("Group ID must be a valid unsigned value")
#     ret = _id_index(match_ptr, c_size_t(id))
#     if not ret:
#         return ret
#     else:
#         return ret.decode('utf-8')

# Requires heap-allocated names.
# def name_to_id(pattern: c_void_p, name: str): # Unpacks optional ID struct to a value or None.
#     if pattern is None:
#         return None
#     id: ZOptional_size_t = _name_to_id(pattern, _to_c_str(name))
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
#     name: c_char_p = _id_to_name(pattern, c_size_t(id))
#     return repr(name)
