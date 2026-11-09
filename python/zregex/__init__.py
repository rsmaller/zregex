from .zregex import *

class Match:
    def __init__(self, match_ptr):
        self.groups = []
        if match_ptr is not None:
            self.__pattern = match_ptr.contents.pattern_ptr
            for i in range(match_ptr.contents.group_count):
                self.groups.append(id_index_internal(match_ptr, i).decode('utf-8'))
        else:
            self.__pattern = None
    def __getitem__(self, key):
        if isinstance(key, int):
            return self.groups[key]
        elif isinstance(key, str):
            if self.__pattern is None:
                return None
            item_id = name_to_id_internal(self.__pattern, to_c_str_internal(key)).unpack()
            if item_id is None:
                return None
            else:
                return self.groups[item_id]
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
        return name_to_id_internal(self.__pattern, to_c_str_internal(name)).unpack()
    def id_to_name(self, item_id: int):
        if self.__pattern is None or item_id is None:
            return None
        if item_id < 0:
            raise Exception("Group ID must be a valid unsigned value")
        name: c_char_p = id_to_name_internal(self.__pattern, item_id)
        if name is not None:
            return bytes(name).decode('utf-8')
        else:
            return None
    def match(self, string: str):
        item = zregex.match_internal(self.__pattern, to_c_str_internal(string))
        if item:
            ret = Match(item)
            destroy_match_internal(item) # Zig's allocated match is immediately destroyed.
            return ret
        else:
            return Match(None) 
    def print_bytecode(self):
        return zregex.print_bytecode_internal(self.__pattern)
    def print_ast(self, show_len: bool):
        options = zregex.ASTPrintOptions()
        options.show_match_width = show_len
        return zregex.print_ast_internal(self.__pattern, options)


def init(): # Hooks into _callback defined below.
    zregex.init_internal(zregex.callback_internal)

def compile(string: str): # noqa
    ret = zregex.compile_internal(zregex.to_c_str_internal(string))
    if ret is None:
        raise Exception("Unable to compile target string")
    return Pattern(ret)

def print_test():
    return zregex.print_test_internal()
