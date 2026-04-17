local function string_split(inputstr, sep)
	if sep == nil then
		sep = "%s"
	end
	local t={}
	for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
		table.insert(t, str)
	end
	return t
end

local function table_clone(tbl)
	if tbl.__meta and tbl.__meta.type == Type.INSTANCE then
		return tbl:clone()
	end
	local clone = {}
	for k, v in pairs(tbl) do
		local vType = type(v)
		local isScalar = vType == "boolean" or vType == "number" or vType == "string"
		if isScalar then
			clone[k] = v
		elseif vType == "table" then
			clone[k] = table_clone(v)
		end
	end
	return clone
end

local packageConfig = string_split(package.config, "\n")
local directorySeparator = packageConfig[1]
local pathDelimiter = packageConfig[2]
local pathSub = packageConfig[3]

local __meta = {
	lastType = nil,
	ns = _G,
	path = nil
}

local function namespace_get_full_name(ns)
	local result = ns.__meta.name
	local current = ns.__meta.parent
	while current do
		result = current.__meta.name.."."..result
		current = current.__meta.parent
	end
	return result
end

local function resolve_full_name(name)
	if __meta.ns ~= _G then
		return namespace_get_full_name(__meta.ns).."."..name
	end
	return name
end

local function resolve_type_from_string(ref)
	local parts = string_split(ref, ".")
	ref = _G
	for i, part in pairs(parts) do
		ref = ref[part]
		if not ref then
			return nil
		end
	end
	return ref
end

local function delete_last_type()
	Type.delete(__meta.lastType)
	__meta.lastType = nil
	__meta.lastTypeStatic = nil
end

local function get_type_name_from_enum(value)
	return switch (value) {
		[Type.INSTANCE] = "instance";
		[Type.CLASS] = "class";
		[Type.NAMESPACE] = "namespace";
	}
end;

local function get_declaration_message_error(entityType, name)
	return "Cannot declare "..get_type_name_from_enum(entityType).." \""..resolve_full_name(name).."\""
end

local function concat_sentence_list(...)
	local sentenceList = {...}
	for i, sentence in pairs(sentenceList) do
		sentenceList[i] = sentence:gsub("^%s*([a-z])", function (fChar)
			return fChar:upper()
		end)
	end
	return table.concat(sentenceList, ". ")
end

local function check_type_name(entityType, name)
	local regex = "^[%a_][%w_]*$"
	switch (entityType) {
		[Type.CLASS] = function ()
			if not name:match(regex) then
				error(concat_sentence_list(get_declaration_message_error(entityType, name), "The name contains invalid characters"))
			end
		end;
		[Type.NAMESPACE] = function ()
			local parts = string_split(name, ".")
			for i, part in ipairs(parts) do
				if not part:match(regex) then
					error(concat_sentence_list(get_declaration_message_error(entityType, name), "The name contains invalid characters"))
				end
			end
		end;
	}
end

local function check_type_absence(entityType, name)
	local foundType = Type.find(resolve_full_name(name))
	if foundType then
		local errMsg = get_declaration_message_error(entityType, name)
		if type(foundType) == "table" and foundType.__meta and foundType.__meta.type then
			error(concat_sentence_list(errMsg, get_type_name_from_enum(foundType.__meta.type).." with this name already exists"))
		else
			error(concat_sentence_list(errMsg, "Global variable with this name already exists"))
		end
	end
end

local function check_ns_can_create(name)
	local parts = string_split(name, ".")
	local lastNS = _G
	for i, part in pairs(parts) do
		local lastNS = lastNS[part]
		if not lastNS or type(lastNS) == "table" and lastNS.__meta and lastNS.__meta.type == Type.NAMESPACE then
			return
		end
	end
	error(concat_sentence_list(get_declaration_message_error(Type.NAMESPACE, name), get_type_name_from_enum(lastNS.__meta.type).." with this name already exists"))
end

local function check_ns_nesting(name)
	if __meta.ns ~= _G then
		error(concat_sentence_list(get_declaration_message_error(Type.NAMESPACE, name), "Nesting namespace declarations are not allowed"))
	end
end

local function check_type_field_absence(entityType, name, descriptor, field)
	if descriptor[field] then
		delete_last_type()
		error(concat_sentence_list(get_declaration_message_error(entityType, name), "Declaration of field \""..field.."\" is not allowed"))
	end
end

local function check_type_not_deriving(entityType, name, typeA, typeB)
	local parents = {
		typeA
	}
	while #parents > 0 do
		local parent = parents[#parents]
		if parent == typeB then
			delete_last_type()
			error(concat_sentence_list(get_declaration_message_error(entityType, name), "Class \""..typeB.__meta.name.."\" is already a base of class \""..typeA.__meta.name.."\""))
		end
		table.remove(parents, #parents)
		local parentBaseList = parent.__meta.parents
		if parentBaseList then
			for k, v in pairs(parentBaseList) do
				table.insert(parents, v)
			end
		end
	end
end

local function check_type_extend_list(entityType, name, extendList)
	for i = 1, #extendList do
		local parent = extendList[i]
		if parent.__meta.type ~= Type.CLASS then
			delete_last_type()
			error(concat_sentence_list(get_declaration_message_error(entityType, name), "Cannot extend "..get_type_name_from_enum(parent.__meta.type).." \""..parent.."\""))
		end
		if parent == __meta.lastType then
			delete_last_type()
			error(concat_sentence_list(get_declaration_message_error(entityType, name), "Class cannot extend itself"))
		end
		for j = i, #extendList do
			if i == j then
				goto continue
			end
			local compareParent = extendList[j]
			check_type_not_deriving(entityType, name, parent, compareParent)
			check_type_not_deriving(entityType, name, compareParent, parent)
			::continue::
		end
	end
end

local function resolve_type_extend_list(entityType, name, extendList)
	local parentList = {}
	for i, parent in pairs(extendList) do
		local parentRef = Type.find(parent)
		if not parentRef then
			delete_last_type()
			error(concat_sentence_list(get_declaration_message_error(entityType, name), "Cannot find "..get_type_name_from_enum(entityType).." \""..parent.."\""))
		end
		table.insert(parentList, parentRef)
	end
	return parentList
end
local _c = {}
local function populate_supers(self, origin, supers, ...)
	local current_super_instance = {}
	local current_parent = {}
	for name, parent in pairs(self.__meta.parents) do
		if name ~= "Object" and name ~= origin.__meta.name then
			current_parent = parent
			current_super_instance = Type.find(name)
			-- print(origin.__meta.name .. " -> "..name)
			-- local _real = _c.type_constructor(current_super_instance, unpack({...}));''
			supers[name] = current_super_instance
			if current_parent.__meta.parents then
				populate_supers(parent, origin, supers)
			end
		end
	end
	return supers
end
local function type_constructor(self, ...)
	if not self.__meta.__proto then
		local _newindex_f=self["[]"] or self.__newindex
		self.__meta.__proto = {
			__index = function(table, key)
				if self.__meta.getsets and self.__meta.getsets[key] and self.__meta.getsets[key].getter then
					if not table.__meta.__settingStack then
						table.__meta.__settingStack = {}
					end
					if table.__meta.__settingStack[key] then
						return rawget(table, key)
					end
					-- Push the key onto the stack
					table.__meta.__settingStack[key] = true
					local result = self.__meta.getsets[key].getter(table)
					table.__meta.__settingStack[key] = nil
					return result
				end
				return self
			end,
			__newindex = function(table, key, value)
				if self.__meta.getsets and self.__meta.getsets[key] and self.__meta.getsets[key].setter then
					-- Check if we're already in a setter for this key (prevent recursion)
					if not table.__meta.__settingStack then
						table.__meta.__settingStack = {}
					end
					if table.__meta.__settingStack[key] then
						-- Direct assignment without calling setter to prevent recursion
						rawset(table, key, value)
						return
					end
					-- Push the key onto the stack
					table.__meta.__settingStack[key] = true
					-- Call the setter
					self.__meta.getsets[key].setter(table, value)
					-- Pop the key from the stack
					table.__meta.__settingStack[key] = nil
					return
				end
				if Class.getset_readonly_error and self.__meta.getsets and self.__meta.getsets[key] and self.__meta.getsets[key].getter then
					error("Getset is readonly for key " .. key.. "!")
					return nil
				end
				return _newindex_f
			end,
			__call = self["()"] or self.__call,
			__tostring = self.__tostring or function (_) return self.__meta.name .. "()" end,
			__concat = self[".."] or self.__concat,
			__metatable = self.__metatable,
			__mode = self.__mode,
			__gc = self.__gc,
			__len = self["#"] or self.__len,
			__pairs = self.__pairs,
			__ipairs = self.__ipairs,
			__add = self["+"] or self.__add,
			__sub = self["-"] or self.__sub,
			__mul = self["*"] or self.__mul,
			__div = self["/"] or self.__div,
			__pow = self["^"] or self.__pow,
			__mod = self["%"] or self.__mod,
			__idiv = self["//"] or self.__idiv,
			__eq = self["=="] or self.__eq,
			__lt = self["<"] or self.__lt,
			__le = self["<="] or self.__le,
			__band = self["&"] or self.__band,
			__bor = self["|"] or self.__bor,
			__bxor = self["~"] or self.__bxor,
			__bnot = self["not"] or self.__bnot,
			__shl = self["<<"] or self.__shl,
			__shr = self[">>"] or self.__shr
		}
	end
	local object = setmetatable({}, self.__meta.__proto)
	
	object.__meta.supers = {}
	if self["@nosuper"] == nil or self["@nosuper"] == false and (self.__meta.name ~= "Object" and  self.__meta.name ~= "Class" )then
		-- Setup super constructors
		local _current_super_instance = {}
		local _current_parent = {}
		if self.__meta.parents then
			object.__meta.supers = populate_supers(self, self, object.__meta.supers, unpack({...}))
		end
	end

	if self.constructor then
		self.constructor(object, unpack({...}))
	end
	object.__meta = {
		type = Type.INSTANCE,
		class = self,
		realtype = {
			name = self.__meta.name,
			parents = self.__meta.parents or {},
			children = nil, -- TODO: add support for children in typeinfo
		}
	}
	object.get_type = function (self1) return self1.__meta.realtype end
	object.get_type_name = function (self1) return self1.__meta.realtype.name end
	return object
end
_c.type_constructor = type_constructor

function _G.static(descriptor)
	if not __meta.lastType then
		error "Static block can only be used inside a class declaration"
	end
	if type(descriptor) ~= "table" then
		delete_last_type()
		error(concat_sentence_list(get_declaration_message_error(__meta.lastType.__meta.type, __meta.lastType.__meta.name), "Static block must be a table"))
	end
	if not __meta.lastTypeStatic then
		__meta.lastTypeStatic = {}
	end
	for k, v in pairs(descriptor) do
		if type(k) == "string" then
			if __meta.lastTypeStatic[k] ~= nil then
				delete_last_type()
				error(concat_sentence_list(get_declaration_message_error(__meta.lastType.__meta.type, __meta.lastType.__meta.name), "Duplicate static field \""..k.."\""))
			end
			__meta.lastTypeStatic[k] = v
		end
	end
	return nil
end

local function process_type_static_block(descriptor)
	if __meta.lastTypeStatic then
		for k, v in pairs(__meta.lastTypeStatic) do
			if descriptor[k] ~= nil then
				delete_last_type()
				error(concat_sentence_list(get_declaration_message_error(__meta.lastType.__meta.type, __meta.lastType.__meta.name), "Static block contains duplicate field \""..k.."\""))
			end
			descriptor[k] = v
		end
		__meta.lastTypeStatic = nil
	end
	if descriptor.static == nil then
		return
	end
	if type(descriptor.static) ~= "table" then
		delete_last_type()
		error(concat_sentence_list(get_declaration_message_error(__meta.lastType.__meta.type, __meta.lastType.__meta.name), "Static block must be a table"))
	end
	for k, v in pairs(descriptor.static) do
		if type(k) == "string" then
			if descriptor[k] ~= nil then
				delete_last_type()
				error(concat_sentence_list(get_declaration_message_error(__meta.lastType.__meta.type, __meta.lastType.__meta.name), "Static block contains duplicate field \""..k.."\""))
			end
			descriptor[k] = v
		end
	end
	descriptor.static = nil
end

local function type_descriptor_handler(descriptor)
	process_type_static_block(descriptor)
	local meta = __meta.lastType.__meta
	__meta.lastTypeDescriptor = descriptor
	check_type_field_absence(meta.type, meta.name, descriptor, "__meta")
	check_type_field_absence(meta.type, meta.name, descriptor, "__index")
	check_type_field_absence(meta.type, meta.name, descriptor, "get_type")
	check_type_field_absence(meta.type, meta.name, descriptor, "get_type_name")
	setmetatable(descriptor, {
		__index = __meta.lastType;
		__call = type_constructor;
	})
	__meta.lastTypeDescriptor = nil
	for parentName, parent in pairs(__meta.lastType.__meta.parents) do
		parent.__meta.children[meta.name] = descriptor
	end
	__meta.ns[meta.name] = descriptor
	__meta.lastType = nil
	-- C++ ClassDB registration
	if classdb_synthetic_added then classdb_synthetic_added(meta.name, descriptor) end
end

local function type_index(self, key)
	local baseClasses = self.__meta.parents
	for name, ref in pairs(baseClasses) do
		local m = ref[key]
		if m then
			-- self[key] = m -- TODO: Need save?
			return m
		end
	end
end

Type = {

	INSTANCE = 0;
	CLASS = 1;
	NAMESPACE = 2;

	find = function (ref)
		local refType = type(ref)
		if refType ~= "string" and not (refType == "table" and ref.__meta) then
			error "Only strings or direct references are allowed as the only argument"
		end
		if refType == "string" then
			return resolve_type_from_string(ref)
		end
		return ref
	end;

	-- TODO: But it does not delete from instances
	delete = function(ref)
		if not ref then
			return
		end
		if type(ref) == "string" then
			ref = resolve_type_from_string(ref)
		end
		if ref == Object then
			error "Deleting \"Object\" class is not allowed"
		end
		if not ref or not ref.__meta or not ref.__meta.type or ref.__meta.type == Type.INSTANCE then
			error "Cannot delete variable. It is not a type"
		end
		local typeName = ref.__meta.name
		for parentName, parent in pairs(ref.__meta.parents) do
			parent.__meta.children[typeName] = nil
			if #parent.__meta.children == 0--[[  and parent ~= Object ]] then
				-- TODO: It throws error sometimes
				-- parent.__meta.children = nil
			end
		end
		if ref.__meta.children then
			for childName, child in pairs(ref.__meta.children) do
				Type.delete(child)
			end
		end
		_G[typeName] = nil
		if classdb_synthetic_erased then classdb_synthetic_erased(typeName) end
	end;

	--- Sets base search path for imports
	setBasePath = function (path)
		if __meta.path then
			local pathParts = string_split(package.path, pathDelimiter)
			local resultPath = {}
			local oldPath = __meta.path..directorySeparator..pathSub..".lua"
			for i = 1, #pathParts do
				if pathParts[i] ~= oldPath then
					table.insert(resultPath, pathParts[i])
				end
			end
			package.path = table.concat(resultPath, pathDelimiter)
		end
		__meta.path = path
		package.path = path..directorySeparator..pathSub..".lua"..pathDelimiter..package.path
	end;
}
--- @class ClassObject
Object = {

	__meta = {
		name = "Object";
		type = Type.CLASS;
		children = {};
	};

	instanceof = function (self, classname)
		if not classname then
			error "Supplied argument is nil"
		end
		local ref = Type.find(classname)
		if not ref then
			if type(classname) == "string" then
				error("Cannot find class \""..classname.."\"")
			else
				error("Cannot find class")
			end
		end
		local parents = {
			self.__meta.class
		}
		while #parents > 0 do
			local parent = parents[#parents]
			if parent == ref then
				break
			end
			table.remove(parents, #parents)
			local parentBaseList = parent.__meta.parents
			if parentBaseList then
				for k, v in pairs(parentBaseList) do
					table.insert(parents, v)
				end
			end
		end
		return #parents > 0
	end;

	clone = function (self)
		local clone = setmetatable({}, getmetatable(self))
		for k, v in pairs(self) do
			local vType = type(v)
			local isScalar = vType == "boolean" or vType == "number" or vType == "string"
			if isScalar or k == "__meta" then
				clone[k] = v
			elseif vType == "table" then
				clone[k] = table_clone(v)
			end
		end
		return clone
	end;

	getClass = function (self)
		return self.__meta.class
	end;
	super = function(self, classname)
		local _super = (self.__meta.supers or {})[classname] or nil
		assert(_super ~= nil, "Supercall must contain a valid class that this object extends from. " .. classname .. " is not a superclass of ")
		return _super
	end;
}
---Get the classname of an object. Identical to self:get_type_name()
---@param instance ClassObject
---@return string
function _G.typename(instance)
	assert(instance.__meta ~= nil, "typeinfo() must be used with a constructed class object!")
	if instance.__meta then
		return instance.__meta.name
	end
	return ""
end

---Get the realtype info from the object. Identical to self:get_type()
---@param instance ClassObject
---@return table
function _G.typeinfo(instance)
	assert(instance.__meta ~= nil, "typeinfo() must be used with a constructed class object!")
	if instance.__meta then
		return instance.__meta.realtype
	end
	return {}
end
function _G.isclass(instance)
	return instance.__meta ~= nil
end
function _G.class(name)
	check_type_name(Type.CLASS, name)
	check_type_absence(Type.CLASS, name)
	local ns = __meta.ns
	if ns == _G then
		ns = nil
	end
	local ref = setmetatable({
		__meta = {
			name = name,
			type = Type.CLASS,
			namespace = ns,
			parents = {
				Object = Object
			}
		}
	}, {
		__index = type_index
	})
	__meta.ns[name] = ref
	__meta.lastType = ref
	__meta.name = name
	return type_descriptor_handler
end
function _G.getset(name, getter, setter)
	local meta = __meta.lastType.__meta
	meta.getsets = meta.getsets or {}
	
	if type(name) == "table" and getter == nil and setter == nil then
		-- Table-based format: getset { ["key"] = { getter = ..., setter = ... } }
		for key, descriptor in pairs(name) do
			if type(descriptor) == "table" then
				meta.getsets[key] = descriptor
			end
		end
	else
		-- Function-based format: getset(name, getter, setter)
		meta.getsets[name] = {}
		meta.getsets[name].getter = getter
		meta.getsets[name].setter = setter
	end
	return type_descriptor_handler
end
function _G.extends(...)
	local parents = {}
	local extendList = resolve_type_extend_list(Type.CLASS, __meta.lastType.__meta.name, {...})
	check_type_extend_list(Type.CLASS, __meta.lastType.__meta.name, extendList)
	for i, parent in pairs(extendList) do
		parents[parent.__meta.name] = parent
		if not parent.__meta.children then
			parent.__meta.children = {}
		end
	end
	__meta.lastType.__meta.parents = parents
	setmetatable(__meta.lastType, {
		__index = type_index
	})
	return type_descriptor_handler
end

function _G.namespace(name)
	check_type_name(Type.NAMESPACE, name)
	check_ns_can_create(name)
	check_ns_nesting(name)
	local nameParts = string_split(name, ".")
	local lastRef = _G
	for i, part in ipairs(nameParts) do
		if not lastRef[part] then
			local parent = lastRef
			if lastRef == _G then
				parent = nil
			end
			lastRef[part] = {
				__meta = {
					name = part,
					parent = parent,
					type = Type.NAMESPACE
				}
			}
		end
		lastRef = lastRef[part]
	end
	__meta.ns = lastRef
	return function (descriptor)
		check_type_field_absence(Type.NAMESPACE, name, descriptor, "__meta")
		check_type_field_absence(Type.NAMESPACE, name, descriptor, "__index")
		for k, v in pairs(descriptor) do
			if type(k) == "string" then
				lastRef[k] = v
			end
		end
		__meta.ns = _G
	end
end

function _G.import(name)
	if name:sub(#name, #name) == "*" then
		local parts = string_split(name, ".")
		parts[#parts] = nil
		local path = table.concat(parts, directorySeparator)
		local result
		if directorySeparator == "/" then
			result = io.popen("ls "..__meta.path.."/"..path):lines()
		else
			result = io.popen("dir "..__meta.path.."\\"..path.." /a:-d /b | findstr \"\\.lua$\""):lines()
		end
		local ns = table.concat(parts, ".")
		for fileName in result do
			local fileBase = fileName:gsub("%.lua$", "")
			require(ns.."."..fileBase)
		end
	else
		require(name)
	end
end

function _G.switch(variable)
	return function (map)
		for case, value in pairs(map) do
			local matches = false
			if type(case) == "table" and (not case.__meta or case.__meta.type ~= Type.INSTANCE) then
				for k, v in pairs(case) do
					if v == variable then
						matches = true
						break
					end
				end
			else
				matches = variable == case
			end
			if matches then
				if type(value) == "function" then
					return value()
				else
					return value
				end
			end
		end
		if map[default] then
			local defaultBranch = map[default]
			if type(defaultBranch) == "function" then
				return defaultBranch()
			else
				return defaultBranch
			end
		end
	end
end

function _G.try(f)
	if type(f) == "table" then
		f = f[1]
	end
	local silent, result = pcall(f)
	return TryCatchFinally(silent, result)
end

function _G.default() end
function _G.null() end -- TODO: Delete?

class 'TryCatchFinally' {

	silent = nil;
	result = nil;
	caught = false;

	constructor = function (self, silent, result)
		self.silent = silent
		self.result = result
	end;
	
	catch = function (self, f)
		if self.caught then
			error "Cannot call catch twice"
		end
		self.caught = true
		if not self.silent then
			if type(f) == "table" then
				f = f[1]
			end
			self.result = f(self.result)
		end
		return self
	end;

	finally = function (self, f)
		if type(f) == "table" then
			f = f[1]
		end
		return f(self.result)
	end;
}

class 'Class' {

	ref = nil;

	constructor = function (self, ref)
		if not ref then
			error "Type reference cannot be nil"
		end
		self.ref = Type.find(ref)
		if not self.ref then
			error("Cannot find type \""..ref.."\"")
		end
	end;

	getMeta = function (self, key)
		if key then
			return self.ref.__meta[key]
		else
			return self.ref.__meta
		end
	end;

	getName = function (self)
		if self.ref.__meta.namespace then
			return namespace_get_full_name(self.ref.__meta.namespace).."."..self.ref.__meta.name
		else
			return self.ref.__meta.name
		end
	end;

	delete = function (self)
		Type.delete(self)
	end;
}
Class.getset_readonly_error = true
Type.setBasePath("src")
