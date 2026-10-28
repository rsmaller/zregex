from ctypes import *
from .zregex import *

class Match:
    def __init__(self, match_ptr):
        self.__pattern = match_ptr.contents.pattern_ptr
        self.groups = []
        for i in range(match_ptr.contents.group_count):
            self.groups.append(id_index_internal(match_ptr, i).decode('utf-8'))
    def __getitem__(self, key):
        if isinstance(key, int):
            return self.groups[key]
        elif isinstance(key, str):
            if self.__pattern is None:
                return None
            id = name_to_id_internal(self.__pattern, to_c_str_internal(key)).unpack()
            if id is None:
                return None
            else:
                return self.groups[id]
        else:
            raise Exception("Invalid value passed to get item method!")
    @property
    def _pattern(self):
        return self.__pattern

class Pattern:
    def __init__(self, pattern_ptr: c_void_p):
        self.__pattern = pattern_ptr
    def __del__(self):
        if self.__pattern is not None:
            destroy_pattern_internal(self.__pattern) # Internal AST in zig must be kept active past compilation point.
    @property
    def _pattern(self):
        return self.__pattern
    def name_to_id(self, name: str): # Unpacks optional ID struct to a value or None.
        if self is None:
            return None
        id = name_to_id_internal(self.__pattern, to_c_str_internal(name)).unpack()
        if id is None:
            return None
        else:
            return id
    def id_to_name(self, id: int):
        if self.__pattern is None:
            return None
        if id < 0:
            raise Exception("Group ID must be a valid unsigned value")
        name: c_char_p = id_to_name_internal(self.__pattern, id)
        if name is not None:
            return name.decode('utf-8')
        else:
            return name
    def match(self, string: str):
        item = zregex.match_internal(self.__pattern, to_c_str_internal(string))
        if item is None:
            return None
        ret = Match(item)
        destroy_match_internal(item) # Zig's allocated match is immediately destroyed.
        return ret
    def print_bytecode(self):
        return zregex.print_bytecode_internal(self.__pattern)
    def print_ast(self, show_len: bool):
        options = zregex.ASTPrintOptions()
        options.show_match_width = show_len
        return zregex.print_ast_internal(self.__pattern, options)


def init(): # Hooks into _callback defined below.
    zregex.init_internal(zregex.callback_internal)

def compile(string: str):
    ret = zregex.compile_internal(zregex.to_c_str_internal(string))
    if ret is None:
        raise Exception("Unable to compile target string")
    return Pattern(ret)

def print_test():
    return zregex.print_test_internal()